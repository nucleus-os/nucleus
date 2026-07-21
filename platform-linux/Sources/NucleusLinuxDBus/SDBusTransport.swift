import NucleusLinuxDBusC
#if canImport(Glibc)
import Glibc
#endif

private let dbusTypeArray = CChar(UInt8(ascii: "a"))
private let dbusTypeBoolean = CChar(UInt8(ascii: "b"))
private let dbusTypeDouble = CChar(UInt8(ascii: "d"))
private let dbusTypeInt16 = CChar(UInt8(ascii: "n"))
private let dbusTypeInt32 = CChar(UInt8(ascii: "i"))
private let dbusTypeObjectPath = CChar(UInt8(ascii: "o"))
private let dbusTypeString = CChar(UInt8(ascii: "s"))
private let dbusTypeStruct = CChar(UInt8(ascii: "r"))
private let dbusTypeUInt32 = CChar(UInt8(ascii: "u"))
private let dbusTypeVariant = CChar(UInt8(ascii: "v"))

private func dbusObjectHandler(
    _ rawMessage: OpaquePointer?,
    _ userData: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<sd_bus_error>?
) -> Int32 {
    guard let rawMessage, let userData else { return -EINVAL }
    let registration = Unmanaged<SDBusObjectRegistration>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let address = UInt(bitPattern: rawMessage)
    return MainActor.assumeIsolated {
        guard registration.isActive,
              let message = OpaquePointer(bitPattern: address)
        else { return -ECANCELED }
        return registration.handler(SDBusMessage(message))
    }
}

private func dbusPendingCallHandler(
    _ rawMessage: OpaquePointer?,
    _ userData: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<sd_bus_error>?
) -> Int32 {
    guard let userData else { return -EINVAL }
    let pending = Unmanaged<SDBusPendingCall>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let address = rawMessage.map { UInt(bitPattern: $0) }
    return MainActor.assumeIsolated {
        guard let handler = pending.takeHandler() else { return 0 }
        guard let address,
              let rawMessage = OpaquePointer(bitPattern: address)
        else {
            handler(.failure(DBusError(
                name: "org.nucleus.DBus.Error.InvalidReply",
                message: "The asynchronous D-Bus call returned no reply")))
            return 1
        }
        let message = SDBusMessage(rawMessage)
        if let failure = message.methodError {
            handler(.failure(failure))
        } else {
            handler(.success(message))
        }
        return 1
    }
}

/// A borrowed message valid only for the duration of an sd-bus callback.
///
/// Callers decode it synchronously. The raw pointer never leaves this module,
/// which keeps message lifetime and Swift/C callback assumptions in one place.
public struct SDBusMessage {
    fileprivate let raw: OpaquePointer

    fileprivate init(_ raw: OpaquePointer) {
        self.raw = raw
    }

    public var path: String {
        Self.string(sd_bus_message_get_path(raw))
    }

    public var interface: String {
        Self.string(sd_bus_message_get_interface(raw))
    }

    public var member: String {
        Self.string(sd_bus_message_get_member(raw))
    }

    public var signature: String {
        Self.string(sd_bus_message_get_signature(raw, 1))
    }

    public var methodError: DBusError? {
        guard nucleus_dbus_message_is_error(raw) != 0 else { return nil }
        return DBusError(
            name: String(cString: nucleus_dbus_message_error_name(raw)),
            message: String(cString: nucleus_dbus_message_error_message(raw)))
    }

    public func readString() -> String? {
        var value: UnsafePointer<CChar>?
        guard sd_bus_message_read_basic(raw, dbusTypeString, &value) > 0,
              let value
        else { return nil }
        return String(cString: value)
    }

    public func readObjectPath() -> String? {
        var value: UnsafePointer<CChar>?
        guard sd_bus_message_read_basic(
            raw, dbusTypeObjectPath, &value) > 0,
            let value
        else { return nil }
        return String(cString: value)
    }

    public func readInt32() -> Int32? {
        var value: Int32 = 0
        guard sd_bus_message_read_basic(raw, dbusTypeInt32, &value) > 0
        else { return nil }
        return value
    }

    public func readUInt32() -> UInt32? {
        var value: UInt32 = 0
        guard sd_bus_message_read_basic(raw, dbusTypeUInt32, &value) > 0
        else { return nil }
        return value
    }

    public func readBoolean() -> Bool? {
        var value: Int32 = 0
        guard sd_bus_message_read_basic(raw, dbusTypeBoolean, &value) > 0
        else { return nil }
        return value != 0
    }

    public func readDouble() -> Double? {
        var value = 0.0
        guard sd_bus_message_read_basic(raw, dbusTypeDouble, &value) > 0
        else { return nil }
        return value
    }

    public func readVariantUInt32() -> UInt32? {
        guard enterContainer(type: dbusTypeVariant, signature: "u") else {
            return nil
        }
        guard let value = readUInt32(), exitContainer() else { return nil }
        return value
    }

    public func readVariantBoolean() -> Bool? {
        guard enterContainer(type: dbusTypeVariant, signature: "b") else {
            return nil
        }
        guard let value = readBoolean(), exitContainer() else { return nil }
        return value
    }

    public func readVariantDouble() -> Double? {
        guard enterContainer(type: dbusTypeVariant, signature: "d") else {
            return nil
        }
        guard let value = readDouble(), exitContainer() else { return nil }
        return value
    }

    public func enterContainer(type: CChar, signature: String) -> Bool {
        signature.withCString {
            sd_bus_message_enter_container(raw, type, $0) > 0
        }
    }

    public func exitContainer() -> Bool {
        sd_bus_message_exit_container(raw) > 0
    }

    public func skip(signature: String) -> Bool {
        signature.withCString { sd_bus_message_skip(raw, $0) >= 0 }
    }

    public func reply(
        _ body: (inout SDBusMessageWriter) -> Int32 = { _ in 0 }
    ) -> Int32 {
        var reply: OpaquePointer?
        let created = sd_bus_message_new_method_return(raw, &reply)
        guard created >= 0, let reply else {
            return created < 0 ? created : -EIO
        }
        defer { sd_bus_message_unref(reply) }
        var writer = SDBusMessageWriter(reply)
        let encoded = body(&writer)
        guard encoded >= 0 else { return encoded }
        return sd_bus_send(nil, reply, nil)
    }

    public func replyError(name: String, message: String) -> Int32 {
        name.withCString { namePointer in
            message.withCString { messagePointer in
                nucleus_dbus_reply_error(raw, namePointer, messagePointer)
            }
        }
    }

    private static func string(
        _ pointer: UnsafePointer<CChar>?
    ) -> String {
        pointer.map(String.init(cString:)) ?? ""
    }
}

public struct SDBusMessageWriter {
    fileprivate let raw: OpaquePointer
    public private(set) var result: Int32 = 0

    fileprivate init(_ raw: OpaquePointer) {
        self.raw = raw
    }

    @discardableResult
    public mutating func string(_ value: String) -> Int32 {
        guard result >= 0 else { return result }
        result = value.withCString {
            sd_bus_message_append_basic(raw, dbusTypeString, $0)
        }
        return result
    }

    @discardableResult
    public mutating func objectPath(_ value: String) -> Int32 {
        guard result >= 0 else { return result }
        result = value.withCString {
            sd_bus_message_append_basic(raw, dbusTypeObjectPath, $0)
        }
        return result
    }

    @discardableResult
    public mutating func int16(_ value: Int16) -> Int32 {
        guard result >= 0 else { return result }
        var value = value
        result = withUnsafePointer(to: &value) {
            sd_bus_message_append_basic(raw, dbusTypeInt16, $0)
        }
        return result
    }

    @discardableResult
    public mutating func int32(_ value: Int32) -> Int32 {
        guard result >= 0 else { return result }
        var value = value
        result = withUnsafePointer(to: &value) {
            sd_bus_message_append_basic(raw, dbusTypeInt32, $0)
        }
        return result
    }

    @discardableResult
    public mutating func uint32(_ value: UInt32) -> Int32 {
        guard result >= 0 else { return result }
        var value = value
        result = withUnsafePointer(to: &value) {
            sd_bus_message_append_basic(raw, dbusTypeUInt32, $0)
        }
        return result
    }

    @discardableResult
    public mutating func boolean(_ value: Bool) -> Int32 {
        guard result >= 0 else { return result }
        var value: Int32 = value ? 1 : 0
        result = withUnsafePointer(to: &value) {
            sd_bus_message_append_basic(raw, dbusTypeBoolean, $0)
        }
        return result
    }

    @discardableResult
    public mutating func double(_ value: Double) -> Int32 {
        guard result >= 0 else { return result }
        var value = value
        result = withUnsafePointer(to: &value) {
            sd_bus_message_append_basic(raw, dbusTypeDouble, $0)
        }
        return result
    }

    @discardableResult
    public mutating func container(
        type: CChar,
        signature: String,
        _ body: (inout SDBusMessageWriter) -> Int32
    ) -> Int32 {
        guard result >= 0 else { return result }
        result = signature.withCString {
            sd_bus_message_open_container(raw, type, $0)
        }
        guard result >= 0 else { return result }
        let bodyResult = body(&self)
        guard bodyResult >= 0 else {
            result = bodyResult
            return result
        }
        result = sd_bus_message_close_container(raw)
        return result
    }

    @discardableResult
    public mutating func structValue(
        signature: String,
        _ body: (inout SDBusMessageWriter) -> Int32
    ) -> Int32 {
        container(type: dbusTypeStruct, signature: signature, body)
    }

    @discardableResult
    public mutating func variant(
        signature: String,
        _ body: (inout SDBusMessageWriter) -> Int32
    ) -> Int32 {
        container(type: dbusTypeVariant, signature: signature, body)
    }

    @discardableResult
    public mutating func objectReference(
        busName: String,
        path: String
    ) -> Int32 {
        structValue(signature: "so") { writer in
            let result = writer.string(busName)
            guard result >= 0 else { return result }
            return writer.objectPath(path)
        }
    }

    @discardableResult
    public mutating func objectReferenceArray(
        _ paths: [String],
        busName: String
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "(so)") { writer in
            for path in paths {
                let result = writer.objectReference(
                    busName: busName, path: path)
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    @discardableResult
    public mutating func stringArray(_ values: [String]) -> Int32 {
        container(type: dbusTypeArray, signature: "s") { writer in
            for value in values {
                let result = writer.string(value)
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    @discardableResult
    public mutating func uint32Array(_ values: [UInt32]) -> Int32 {
        container(type: dbusTypeArray, signature: "u") { writer in
            for value in values {
                let result = writer.uint32(value)
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    @discardableResult
    public mutating func stringDictionary(
        _ values: [String: String]
    ) -> Int32 {
        let dictionaryType = CChar(UInt8(ascii: "e"))
        return container(type: dbusTypeArray, signature: "{ss}") { writer in
            for key in values.keys.sorted() {
                let result = writer.container(
                    type: dictionaryType, signature: "ss"
                ) {
                    let result = $0.string(key)
                    guard result >= 0 else { return result }
                    return $0.string(values[key] ?? "")
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    @discardableResult
    public mutating func stringVariantDictionary(
        _ values: [String: String]
    ) -> Int32 {
        let dictionaryType = CChar(UInt8(ascii: "e"))
        return container(type: dbusTypeArray, signature: "{sv}") { writer in
            for key in values.keys.sorted() {
                let result = writer.container(
                    type: dictionaryType, signature: "sv"
                ) {
                    let result = $0.string(key)
                    guard result >= 0 else { return result }
                    return $0.variant(signature: "s") {
                        $0.string(values[key] ?? "")
                    }
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }
}

@MainActor
public final class SDBusObjectRegistration {
    fileprivate var slot: OpaquePointer?
    fileprivate weak var owner: SDBusConnection?
    fileprivate let handler: @MainActor (borrowing SDBusMessage) -> Int32

    fileprivate init(
        handler: @escaping @MainActor (borrowing SDBusMessage) -> Int32
    ) {
        self.handler = handler
    }

    fileprivate var isActive: Bool { slot != nil }

    public func cancel() {
        guard let slot else { return }
        self.slot = nil
        sd_bus_slot_unref(slot)
        let owner = owner
        self.owner = nil
        owner?.registrationDidCancel(self)
    }

    isolated deinit {
        cancel()
    }
}

@MainActor
public final class SDBusPendingCall {
    fileprivate var slot: OpaquePointer?
    fileprivate weak var owner: SDBusConnection?
    private var handler:
        (@MainActor (Result<SDBusMessage, DBusError>) -> Void)?

    fileprivate init(
        handler: @escaping @MainActor (
            Result<SDBusMessage, DBusError>) -> Void
    ) {
        self.handler = handler
    }

    fileprivate func takeHandler() -> (
        @MainActor (Result<SDBusMessage, DBusError>) -> Void
    )? {
        let handler = handler
        self.handler = nil
        cancelSlot()
        return handler
    }

    public func cancel() {
        handler = nil
        cancelSlot()
    }

    private func cancelSlot() {
        if let slot {
            self.slot = nil
            sd_bus_slot_unref(slot)
        }
        let owner = owner
        self.owner = nil
        owner?.pendingCallDidFinish(self)
    }

    isolated deinit {
        cancel()
    }
}

/// Concrete owner for one nonblocking sd-bus connection.
///
/// It centralizes raw handles, slot lifetime, callbacks, polling, async calls,
/// object registration, and message construction. Protocol-specific services
/// retain this owner but never import libsystemd themselves.
@MainActor
public final class SDBusConnection {
    private var bus: OpaquePointer?
    private var registrations: [ObjectIdentifier: SDBusObjectRegistration] = [:]
    private var pendingCalls: [ObjectIdentifier: SDBusPendingCall] = [:]

    public init(_ kind: DBusBus) throws(DBusError) {
        var handle: OpaquePointer?
        let result: Int32 = switch kind {
        case .session: sd_bus_open_user(&handle)
        case .system: sd_bus_open_system(&handle)
        }
        guard result >= 0, let handle else {
            throw DBusError(errno: result, while: "opening the \(kind) bus")
        }
        bus = handle
    }

    public init(address: String) throws(DBusError) {
        var handle: OpaquePointer?
        var result = sd_bus_new(&handle)
        guard result >= 0, let handle else {
            throw DBusError(errno: result, while: "creating a D-Bus connection")
        }
        bus = handle
        result = address.withCString { sd_bus_set_address(handle, $0) }
        guard result >= 0 else {
            close()
            throw DBusError(errno: result, while: "setting the D-Bus address")
        }
        result = sd_bus_set_bus_client(handle, 1)
        guard result >= 0 else {
            close()
            throw DBusError(errno: result, while: "configuring a D-Bus client")
        }
        result = sd_bus_start(handle)
        guard result >= 0 else {
            close()
            throw DBusError(errno: result, while: "starting a D-Bus connection")
        }
    }

    isolated deinit {
        close()
    }

    public var isOpen: Bool { bus != nil }

    public var uniqueName: String? {
        guard let bus else { return nil }
        var value: UnsafePointer<CChar>?
        guard sd_bus_get_unique_name(bus, &value) >= 0, let value else {
            return nil
        }
        return String(cString: value)
    }

    public var fileDescriptor: Int32 {
        guard let bus else { return -1 }
        let descriptor = sd_bus_get_fd(bus)
        return descriptor >= 0 ? descriptor : -1
    }

    public var pollEvents: Int16 {
        guard let bus else { return 0 }
        let events = sd_bus_get_events(bus)
        return events >= 0 ? Int16(truncatingIfNeeded: events) : 0
    }

    public func timeoutMicroseconds() -> UInt64? {
        guard let bus else { return nil }
        var deadline: UInt64 = 0
        guard sd_bus_get_timeout(bus, &deadline) >= 0,
              deadline != UInt64.max
        else { return nil }
        let now = Self.monotonicMicroseconds()
        return deadline > now ? deadline - now : 0
    }

    @discardableResult
    public func process() throws(DBusError) -> Bool {
        guard let bus else { return false }
        var handled = false
        while true {
            let result = sd_bus_process(bus, nil)
            if result < 0 {
                throw DBusError(errno: result, while: "processing D-Bus")
            }
            if result == 0 { break }
            handled = true
        }
        let flushed = sd_bus_flush(bus)
        if flushed < 0 {
            throw DBusError(errno: flushed, while: "flushing D-Bus")
        }
        return handled
    }

    public func registerFallback(
        path: String,
        handler: @escaping @MainActor (borrowing SDBusMessage) -> Int32
    ) throws(DBusError) -> SDBusObjectRegistration {
        guard let bus else { throw DBusError.closed }
        let registration = SDBusObjectRegistration(handler: handler)
        var slot: OpaquePointer?
        let result = path.withCString {
            sd_bus_add_fallback(
                bus, &slot, $0, dbusObjectHandler,
                Unmanaged.passUnretained(registration).toOpaque())
        }
        guard result >= 0, let slot else {
            throw DBusError(
                errno: result < 0 ? result : -EIO,
                while: "registering the D-Bus object subtree")
        }
        registration.slot = slot
        registration.owner = self
        registrations[ObjectIdentifier(registration)] = registration
        return registration
    }

    @discardableResult
    public func callAsync(
        service: String,
        path: String,
        interface: String,
        member: String,
        encode: (inout SDBusMessageWriter) -> Int32 = { _ in 0 },
        completion: @escaping @MainActor (
            Result<SDBusMessage, DBusError>) -> Void
    ) throws(DBusError) -> SDBusPendingCall {
        guard let bus else { throw DBusError.closed }
        var rawMessage: OpaquePointer?
        let created = sd_bus_message_new_method_call(
            bus, &rawMessage, service, path, interface, member)
        guard created >= 0, let rawMessage else {
            throw DBusError(
                errno: created, while: "building \(interface).\(member)")
        }
        defer { sd_bus_message_unref(rawMessage) }
        var writer = SDBusMessageWriter(rawMessage)
        let encoded = encode(&writer)
        guard encoded >= 0 else {
            throw DBusError(
                errno: encoded, while: "encoding \(interface).\(member)")
        }

        let pending = SDBusPendingCall(handler: completion)
        var slot: OpaquePointer?
        let result = sd_bus_call_async(
            bus, &slot, rawMessage, dbusPendingCallHandler,
            Unmanaged.passUnretained(pending).toOpaque(), 0)
        guard result >= 0, let slot else {
            throw DBusError(
                errno: result < 0 ? result : -EIO,
                while: "sending \(interface).\(member)")
        }
        pending.slot = slot
        pending.owner = self
        pendingCalls[ObjectIdentifier(pending)] = pending
        return pending
    }

    @discardableResult
    public func emitSignal(
        path: String,
        interface: String,
        member: String,
        encode: (inout SDBusMessageWriter) -> Int32
    ) -> Int32 {
        guard let bus else { return -ENOTCONN }
        var rawMessage: OpaquePointer?
        let created = path.withCString { pathPointer in
            interface.withCString { interfacePointer in
                member.withCString { memberPointer in
                    sd_bus_message_new_signal(
                        bus, &rawMessage, pathPointer,
                        interfacePointer, memberPointer)
                }
            }
        }
        guard created >= 0, let rawMessage else {
            return created < 0 ? created : -EIO
        }
        defer { sd_bus_message_unref(rawMessage) }
        var writer = SDBusMessageWriter(rawMessage)
        let encoded = encode(&writer)
        guard encoded >= 0 else { return encoded }
        return sd_bus_send(bus, rawMessage, nil)
    }

    public func close(flush: Bool = true) {
        let livePending = Array(pendingCalls.values)
        pendingCalls.removeAll(keepingCapacity: false)
        for pending in livePending { pending.cancel() }
        let liveRegistrations = Array(registrations.values)
        registrations.removeAll(keepingCapacity: false)
        for registration in liveRegistrations { registration.cancel() }
        if let bus {
            if flush { _ = sd_bus_flush(bus) }
            sd_bus_unref(bus)
        }
        bus = nil
    }

    fileprivate func registrationDidCancel(
        _ registration: SDBusObjectRegistration
    ) {
        registrations.removeValue(forKey: ObjectIdentifier(registration))
    }

    fileprivate func pendingCallDidFinish(_ pending: SDBusPendingCall) {
        pendingCalls.removeValue(forKey: ObjectIdentifier(pending))
    }

    package var rawHandle: OpaquePointer? { bus }

    private static func monotonicMicroseconds() -> UInt64 {
        var now = timespec()
        _ = clock_gettime(CLOCK_MONOTONIC, &now)
        let seconds = UInt64(max(0, now.tv_sec))
        let microseconds = UInt64(max(0, now.tv_nsec)) / 1_000
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !multiplied.overflow else { return .max }
        let added = multiplied.partialValue.addingReportingOverflow(microseconds)
        return added.overflow ? .max : added.partialValue
    }
}
