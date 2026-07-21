import NucleusLinuxDBusC
#if canImport(Glibc)
import Glibc
#endif

/// Which bus a connection talks to.
///
/// Session for per-user services — MPRIS, notifications, the tray. System for
/// machine-wide ones — UPower, BlueZ, NetworkManager, logind. A shell needs
/// both, and which one a service lives on is not a detail its client gets to
/// guess.
public enum DBusBus: Sendable, Equatable {
    case session
    case system
}

/// A D-Bus failure, carrying the peer's own error name where there is one.
///
/// `name` is the D-Bus error name (`org.freedesktop.DBus.Error.ServiceUnknown`
/// and friends), which is the part worth branching on; `message` is human text
/// and is not.
public struct DBusError: Error, Equatable, Sendable {
    public var name: String
    public var message: String
    public var systemCode: Int32?

    public init(
        name: String,
        message: String,
        systemCode: Int32? = nil
    ) {
        self.name = name
        self.message = message
        self.systemCode = systemCode
    }

    /// A failure reported as a negative errno rather than a bus error.
    public init(errno code: Int32, while action: String) {
        let normalizedCode = code < 0 ? code : -EIO
        self.name = "org.nucleus.DBus.Error.System"
        self.message = "\(action): \(String(cString: strerror(-normalizedCode)))"
        self.systemCode = normalizedCode
    }

    /// Whether the peer is simply not running. Distinguishable because a shell
    /// widget for an absent service should render as unavailable rather than as
    /// broken — a laptop without bluetooth hardware has no BlueZ.
    public var isServiceUnavailable: Bool {
        name == "org.freedesktop.DBus.Error.ServiceUnknown"
            || name == "org.freedesktop.DBus.Error.NameHasNoOwner"
    }
}

/// A subscription token. Dropping it removes the match.
@MainActor
public final class DBusSubscription {
    fileprivate var slot: OpaquePointer?
    fileprivate let handler: () -> Void
    fileprivate weak var owner: DBusConnection?

    fileprivate init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// Stop delivery and release the sd-bus match slot. Idempotent.
    public func cancel() {
        guard let slot else { return }
        self.slot = nil
        sd_bus_slot_unref(slot)
        let owner = owner
        self.owner = nil
        owner?.subscriptionDidCancel(self)
    }

    var isCancelled: Bool { slot == nil }

    isolated deinit {
        cancel()
    }
}

/// A client connection to a D-Bus bus.
///
/// Non-blocking and driven by the host's event loop: the connection exposes its
/// file descriptor, the events it wants, and its timeout, and `process()` is
/// called when any of them fires. The explicitly synchronous property and method
/// APIs are for cold-path clients; event-loop services use the asynchronous APIs.
@MainActor
public final class DBusConnection {
    private final class WeakSubscription {
        weak var value: DBusSubscription?

        init(_ value: DBusSubscription) {
            self.value = value
        }
    }

    private var transport: SDBusConnection?
    private var subscriptions: [WeakSubscription] = []

    private var bus: OpaquePointer? { transport?.rawHandle }

    public let kind: DBusBus

    public init(_ kind: DBusBus) throws(DBusError) {
        self.kind = kind
        transport = try SDBusConnection(kind)
    }

    isolated deinit {
        close()
    }

    /// Close the connection. Idempotent; the connection is unusable afterwards.
    public func close() {
        compactSubscriptions()
        let liveSubscriptions = subscriptions.compactMap(\.value)
        subscriptions.removeAll(keepingCapacity: true)
        for subscription in liveSubscriptions {
            subscription.cancel()
        }
        transport?.close()
        transport = nil
    }

    public var isOpen: Bool { transport?.isOpen == true }

    // MARK: - Event-loop integration

    /// The descriptor to poll. `-1` once closed.
    public var fileDescriptor: Int32 {
        transport?.fileDescriptor ?? -1
    }

    /// The poll events the connection currently wants. sd-bus asks for write
    /// interest only while it has something queued, so this is re-read each
    /// iteration rather than cached.
    public var pollEvents: Int16 {
        transport?.pollEvents ?? 0
    }

    /// How long the loop may sleep before the connection needs attention, or
    /// `nil` for "no deadline of its own". sd-bus reports an absolute
    /// CLOCK_MONOTONIC deadline; this converts it to a relative wait, clamped at
    /// zero for a deadline already past.
    public func timeoutMicroseconds() -> UInt64? {
        transport?.timeoutMicroseconds()
    }

    /// Dispatch everything the connection has ready, then flush what it queued.
    ///
    /// Returns whether any message was handled, so a caller can tell a spurious
    /// wakeup from real work. Signal handlers run inside this call, which is why
    /// it belongs on the main actor with the rest of the UI.
    @discardableResult
    public func process() throws(DBusError) -> Bool {
        compactSubscriptions()
        defer { compactSubscriptions() }
        return try transport?.process() ?? false
    }

    // MARK: - Properties

    public func propertyBool(
        service: String, path: String, interface: String, member: String
    ) throws(DBusError) -> Bool {
        var value: Int32 = 0
        try readTrivialProperty(
            service: service, path: path, interface: interface, member: member,
            type: CChar(UInt8(ascii: "b")), into: &value)
        return value != 0
    }

    public func propertyUInt32(
        service: String, path: String, interface: String, member: String
    ) throws(DBusError) -> UInt32 {
        var value: UInt32 = 0
        try readTrivialProperty(
            service: service, path: path, interface: interface, member: member,
            type: CChar(UInt8(ascii: "u")), into: &value)
        return value
    }

    public func propertyInt64(
        service: String, path: String, interface: String, member: String
    ) throws(DBusError) -> Int64 {
        var value: Int64 = 0
        try readTrivialProperty(
            service: service, path: path, interface: interface, member: member,
            type: CChar(UInt8(ascii: "x")), into: &value)
        return value
    }

    public func propertyDouble(
        service: String, path: String, interface: String, member: String
    ) throws(DBusError) -> Double {
        var value: Double = 0
        try readTrivialProperty(
            service: service, path: path, interface: interface, member: member,
            type: CChar(UInt8(ascii: "d")), into: &value)
        return value
    }

    public func propertyString(
        service: String, path: String, interface: String, member: String
    ) throws(DBusError) -> String {
        guard let bus else { throw DBusError.closed }
        var error = sd_bus_error()
        nucleus_dbus_error_init(&error)
        defer { sd_bus_error_free(&error) }

        var raw: UnsafeMutablePointer<CChar>?
        let result = sd_bus_get_property_string(
            bus, service, path, interface, member, &error, &raw)
        defer { free(raw) }
        try check(result, error: &error, while: "reading \(interface).\(member)")
        guard let raw else { return "" }
        return String(cString: raw)
    }

    public func portalSettingUInt32Async(
        service: String,
        path: String,
        interface: String,
        namespace: String,
        key: String,
        completion: @escaping @MainActor (Result<UInt32, DBusError>) -> Void
    ) throws(DBusError) -> SDBusPendingCall {
        try portalSettingAsync(
            service: service, path: path, interface: interface,
            namespace: namespace, key: key,
            decode: { $0.readVariantUInt32() },
            completion: completion)
    }

    public func portalSettingBoolAsync(
        service: String,
        path: String,
        interface: String,
        namespace: String,
        key: String,
        completion: @escaping @MainActor (Result<Bool, DBusError>) -> Void
    ) throws(DBusError) -> SDBusPendingCall {
        try portalSettingAsync(
            service: service, path: path, interface: interface,
            namespace: namespace, key: key,
            decode: { $0.readVariantBoolean() },
            completion: completion)
    }

    public func portalSettingDoubleAsync(
        service: String,
        path: String,
        interface: String,
        namespace: String,
        key: String,
        completion: @escaping @MainActor (Result<Double, DBusError>) -> Void
    ) throws(DBusError) -> SDBusPendingCall {
        try portalSettingAsync(
            service: service, path: path, interface: interface,
            namespace: namespace, key: key,
            decode: { $0.readVariantDouble() },
            completion: completion)
    }

    private func portalSettingAsync<Value>(
        service: String,
        path: String,
        interface: String,
        namespace: String,
        key: String,
        decode: @escaping (SDBusMessage) -> Value?,
        completion: @escaping @MainActor (Result<Value, DBusError>) -> Void
    ) throws(DBusError) -> SDBusPendingCall {
        guard let transport else { throw DBusError.closed }
        return try transport.callAsync(
            service: service,
            path: path,
            interface: interface,
            member: "ReadOne",
            encode: {
                let namespaceResult = $0.string(namespace)
                guard namespaceResult >= 0 else { return namespaceResult }
                return $0.string(key)
            }
        ) { result in
            switch result {
            case .success(let message):
                guard let value = decode(message) else {
                    completion(.failure(DBusError(
                        name: "org.nucleus.DBus.Error.InvalidReply",
                        message: "Portal setting \(namespace).\(key) has the wrong type")))
                    return
                }
                completion(.success(value))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func readTrivialProperty<T>(
        service: String, path: String, interface: String, member: String,
        type: CChar, into value: inout T
    ) throws(DBusError) {
        guard let bus else { throw DBusError.closed }
        var error = sd_bus_error()
        nucleus_dbus_error_init(&error)
        defer { sd_bus_error_free(&error) }

        let result = withUnsafeMutablePointer(to: &value) { pointer in
            sd_bus_get_property_trivial(
                bus, service, path, interface, member, &error, type, pointer)
        }
        try check(result, error: &error, while: "reading \(interface).\(member)")
    }

    // MARK: - Methods

    /// Call a method taking no arguments and ignore its reply.
    ///
    /// The shape almost every shell action has: `Suspend`, `Lock`, `Next`,
    /// `PowerOff`. Calls with arguments or meaningful replies are added when a
    /// service needs them rather than speculatively.
    public func call(
        service: String, path: String, interface: String, member: String
    ) throws(DBusError) {
        guard let bus else { throw DBusError.closed }
        var error = sd_bus_error()
        nucleus_dbus_error_init(&error)
        defer { sd_bus_error_free(&error) }

        var message: OpaquePointer?
        let created = sd_bus_message_new_method_call(
            bus, &message, service, path, interface, member)
        guard created >= 0, let message else {
            throw DBusError(errno: created, while: "building \(interface).\(member)")
        }
        defer { sd_bus_message_unref(message) }

        var reply: OpaquePointer?
        let result = sd_bus_call(bus, message, 0, &error, &reply)
        if let reply { sd_bus_message_unref(reply) }
        try check(result, error: &error, while: "calling \(interface).\(member)")
    }

    // MARK: - Signals

    /// Subscribe to signals matching a rule, holding the subscription for as
    /// long as you want the callback.
    ///
    /// The handler takes no arguments on purpose. Decoding a signal body means a
    /// full variant reader, and the pattern a shell widget actually uses is
    /// "something changed, re-read what I display" — `PropertiesChanged` even
    /// carries an invalidated-properties list precisely because the payload is
    /// not always authoritative. A signal whose *body* matters gets a decoder
    /// when a service needs one.
    @discardableResult
    public func subscribe(
        matching rule: String, handler: @escaping () -> Void
    ) throws(DBusError) -> DBusSubscription {
        compactSubscriptions()
        guard let bus else { throw DBusError.closed }
        let subscription = DBusSubscription(handler: handler)
        var slot: OpaquePointer?
        // The slot borrows `subscription`. Both are main-actor confined, and
        // DBusSubscription.deinit synchronously unrefs the slot before ARC can
        // release the callback object.
        let result = sd_bus_add_match(
            bus, &slot, rule,
            { _, userData, _ in
                guard let userData else { return 0 }
                let subscription = Unmanaged<DBusSubscription>
                    .fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { subscription.handler() }
                return 0
            },
            Unmanaged.passUnretained(subscription).toOpaque())
        subscription.slot = slot
        guard result >= 0 else {
            subscription.cancel()
            throw DBusError(errno: result, while: "subscribing to \(rule)")
        }
        guard slot != nil else {
            throw DBusError(
                name: "org.nucleus.DBus.Error.System",
                message: "subscribing to \(rule): sd-bus returned no match slot")
        }
        subscription.owner = self
        subscriptions.append(WeakSubscription(subscription))
        return subscription
    }

    /// Stop delivering a subscription's callback.
    public func cancel(_ subscription: DBusSubscription) {
        subscription.cancel()
        compactSubscriptions()
    }

    fileprivate func subscriptionDidCancel(
        _ subscription: DBusSubscription
    ) {
        subscriptions.removeAll {
            $0.value == nil || $0.value === subscription
        }
    }

    private func compactSubscriptions() {
        subscriptions.removeAll { $0.value == nil }
    }

    /// A match rule for `PropertiesChanged` on one object, the signal nearly
    /// every service uses to announce state.
    public static func propertiesChangedRule(
        service: String, path: String, interface: String
    ) -> String {
        """
        type='signal',\
        sender='\(service)',\
        path='\(path)',\
        interface='org.freedesktop.DBus.Properties',\
        member='PropertiesChanged',\
        arg0='\(interface)'
        """
    }

    // MARK: - Errors

    private func check(
        _ result: Int32, error: inout sd_bus_error, while action: String
    ) throws(DBusError) {
        guard result < 0 else { return }
        if nucleus_dbus_error_is_set(&error) != 0 {
            throw DBusError(
                name: String(cString: nucleus_dbus_error_name(&error)),
                message: String(cString: nucleus_dbus_error_message(&error)))
        }
        throw DBusError(errno: result, while: action)
    }
}

extension DBusError {
    static let closed = DBusError(
        name: "org.nucleus.DBus.Error.Closed",
        message: "The connection is closed")
}
