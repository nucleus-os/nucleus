import Glibc
import Testing
@testable import NucleusLinuxDBus

@MainActor
private final class InjectedDBusEventLoop {
    var processResults: [Int32]
    var flushResult: Int32
    var processCalls = 0
    var flushCalls = 0
    var closeCalls = 0

    init(
        processResults: [Int32],
        flushResult: Int32 = 0
    ) {
        self.processResults = processResults
        self.flushResult = flushResult
    }

    var operations: SDBusEventLoopOperations {
        SDBusEventLoopOperations(
            fileDescriptor: { 73 },
            pollEvents: { 5 },
            timeoutMicroseconds: { 11 },
            process: { [self] in
                processCalls += 1
                return processResults.isEmpty
                    ? 0 : processResults.removeFirst()
            },
            flush: { [self] in
                flushCalls += 1
                return flushResult
            },
            close: { [self] in closeCalls += 1 })
    }
}

/// The shared Linux D-Bus client seam, against a real bus where one is reachable.
///
/// Every bus test degrades to a skip rather than a failure when no bus is
/// present: a build machine without a session bus is a legitimate environment,
/// and a suite that fails there would just get disabled. The pure parts — rule
/// construction, error classification — always run.
@MainActor
@Suite struct DBusConnectionTests {
    /// `nil` when the bus is unreachable, which callers treat as "skip".
    private func connect(_ bus: DBusBus) -> DBusConnection? {
        try? DBusConnection(bus)
    }

    private var nameOwnerChangedRule: String {
        """
        type='signal',\
        sender='org.freedesktop.DBus',\
        interface='org.freedesktop.DBus',\
        member='NameOwnerChanged'
        """
    }

    private func pump(
        _ connection: DBusConnection,
        until predicate: () -> Bool = { false }
    ) throws {
        for _ in 0..<50 {
            _ = try connection.process()
            if predicate() { return }
        }
    }

    // MARK: - Connecting

    @Test func aSessionConnectionOpensAndReportsADescriptor() throws {
        guard let connection = connect(.session) else { return }
        #expect(connection.isOpen)
        #expect(connection.fileDescriptor >= 0)
        #expect(connection.kind == .session)
    }

    @Test func aSystemConnectionOpens() throws {
        guard let connection = connect(.system) else { return }
        #expect(connection.isOpen)
        #expect(connection.fileDescriptor >= 0)
    }

    /// Closing is idempotent, and a closed connection reports itself closed
    /// rather than handing out a stale descriptor.
    @Test func closingIsIdempotentAndLeavesNoDescriptor() throws {
        guard let connection = connect(.session) else { return }
        connection.close()
        connection.close()

        #expect(!connection.isOpen)
        #expect(connection.fileDescriptor == -1)
    }

    @Test func usingAClosedConnectionThrowsRatherThanCrashing() throws {
        guard let connection = connect(.session) else { return }
        connection.close()

        #expect(throws: DBusError.self) {
            try connection.propertyString(
                service: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus", member: "Anything")
        }
    }

    // MARK: - Event-loop integration

    /// The connection reports what a poll loop needs: a descriptor, the events
    /// it wants, and how long the loop may sleep.
    @Test func theConnectionDescribesItsPollInterest() throws {
        guard let connection = connect(.session) else { return }
        #expect(connection.pollEvents != 0, "it wants to read at rest")

        // A timeout of nil means "no deadline of my own", which is legitimate;
        // a value must be a plausible relative wait, not an absolute clock.
        if let timeout = connection.timeoutMicroseconds() {
            #expect(timeout < 60 * 60 * 1_000_000, "relative, not an absolute deadline")
        }
    }

    /// Processing converges: a bus with nothing left to say eventually reports
    /// no work. Bounded rather than asserted on the second call, because the
    /// daemon keeps announcing bus-wide traffic that has nothing to do with us.
    @Test func processingConvergesOnAQuietBus() throws {
        guard let connection = connect(.session) else { return }
        var settled = false
        for _ in 0..<100 {
            if try connection.process() == false {
                settled = true
                break
            }
        }
        #expect(settled)
    }

    @Test func anAsyncCompletionMayCloseItsProcessingConnection() throws {
        guard let connection = try? SDBusConnection(.session) else { return }
        var completed = false
        let pending = try connection.callAsync(
            service: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus.Peer",
            member: "Ping"
        ) { result in
            if case .failure(let error) = result {
                Issue.record("bus daemon Ping failed: \(error)")
            }
            completed = true
            connection.close(flush: false)
        }

        for _ in 0..<100 where !completed {
            _ = try connection.process()
        }
        #expect(completed)
        #expect(!connection.isOpen)
        _ = pending
    }

    @Test func injectedTransportProcessesUntilIdleAndClosesExactlyOnce() throws {
        let eventLoop = InjectedDBusEventLoop(
            processResults: [1, 1, 0])
        let transport = SDBusConnection(
            testing: eventLoop.operations)
        let connection = DBusConnection(
            .session, testing: transport)

        #expect(connection.isOpen)
        #expect(connection.fileDescriptor == 73)
        #expect(connection.pollEvents == 5)
        #expect(connection.timeoutMicroseconds() == 11)
        #expect(try connection.process())
        #expect(eventLoop.processCalls == 3)
        #expect(eventLoop.flushCalls == 1)

        connection.close()
        connection.close()
        #expect(!connection.isOpen)
        #expect(connection.fileDescriptor == -1)
        #expect(eventLoop.flushCalls == 2)
        #expect(eventLoop.closeCalls == 1)
    }

    @Test func injectedProcessAndFlushFailuresRemainTyped() {
        let processFailure = InjectedDBusEventLoop(
            processResults: [-ECONNRESET])
        let processConnection = DBusConnection(
            .session,
            testing: SDBusConnection(
                testing: processFailure.operations))
        do {
            _ = try processConnection.process()
            Issue.record("injected process failure unexpectedly succeeded")
        } catch {
            #expect(error.systemCode == -ECONNRESET)
            #expect(error.message.contains("processing D-Bus"))
        }
        #expect(processFailure.flushCalls == 0)
        processConnection.close()

        let flushFailure = InjectedDBusEventLoop(
            processResults: [0],
            flushResult: -EPIPE)
        let flushConnection = DBusConnection(
            .session,
            testing: SDBusConnection(
                testing: flushFailure.operations))
        do {
            _ = try flushConnection.process()
            Issue.record("injected flush failure unexpectedly succeeded")
        } catch {
            #expect(error.systemCode == -EPIPE)
            #expect(error.message.contains("flushing D-Bus"))
        }
        #expect(flushFailure.processCalls == 1)
        #expect(flushFailure.flushCalls == 1)
        flushConnection.close()
    }

    // MARK: - Properties

    /// The bus daemon is the one peer guaranteed present, so it is what a real
    /// round trip can be tested against. `Peer.Ping` takes no arguments and
    /// returns nothing, which is the exact shape `call` supports.
    @Test func aMethodCallRoundTripsToTheBusDaemon() throws {
        guard let connection = connect(.session) else { return }
        try connection.call(
            service: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus.Peer",
            member: "Ping")
    }

    @Test func callingAnAbsentServiceReportsItUnavailable() throws {
        guard let connection = connect(.session) else { return }
        do {
            try connection.call(
                service: "org.nucleus.NoSuchService",
                path: "/org/nucleus/Nothing",
                interface: "org.freedesktop.DBus.Peer",
                member: "Ping")
            Issue.record("a call to an absent service should not succeed")
        } catch {
            #expect(error.isServiceUnavailable)
        }
    }

    /// Reading a property at the wrong type fails rather than returning
    /// nonsense. `Features` is an array of strings, not a string.
    @Test func aWronglyTypedPropertyReadFails() throws {
        guard let connection = connect(.session) else { return }
        #expect(throws: DBusError.self) {
            try connection.propertyString(
                service: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus",
                member: "Features")
        }
    }

    @Test func anAbsentServiceReportsItselfUnavailable() throws {
        guard let connection = connect(.session) else { return }
        do {
            _ = try connection.propertyString(
                service: "org.nucleus.NoSuchService",
                path: "/org/nucleus/Nothing",
                interface: "org.nucleus.Nothing",
                member: "Anything")
            Issue.record("a call to an absent service should not succeed")
        } catch {
            #expect(error.isServiceUnavailable,
                    "classified as absent, not as broken: \(error.name)")
        }
    }

    @Test func desktopPortalSettingsReadCompletesAsynchronouslyAsOneSnapshot() throws {
        guard let client = connect(.session),
              let server = try? SDBusConnection(.session),
              let service = server.uniqueName
        else { return }
        let path = "/org/nucleus/TestPortal"
        let interface = "org.nucleus.TestPortal.Settings"
        let registration = try server.registerFallback(path: path) { message in
            guard message.interface == interface,
                  message.member == "ReadOne",
                  let namespace = message.readString(),
                  let key = message.readString()
            else {
                return message.replyError(
                    name: "org.freedesktop.DBus.Error.InvalidArgs",
                    message: "invalid fixture call")
            }
            switch (namespace, key) {
            case ("org.freedesktop.appearance", "color-scheme"):
                return message.reply { $0.variant(signature: "u") { $0.uint32(2) } }
            case ("org.freedesktop.appearance", "contrast"):
                return message.reply { $0.variant(signature: "u") { $0.uint32(1) } }
            case ("org.freedesktop.appearance", "reduced-motion"):
                return message.reply { $0.variant(signature: "b") { $0.boolean(true) } }
            case ("org.gnome.desktop.interface", "enable-animations"):
                return message.reply { $0.variant(signature: "b") { $0.boolean(false) } }
            case ("org.freedesktop.appearance", "reduced-transparency"):
                return message.reply { $0.variant(signature: "b") { $0.boolean(true) } }
            case ("org.freedesktop.appearance", "text-scale"):
                return message.replyError(
                    name: "org.freedesktop.portal.Error.NotFound",
                    message: "fixture exercises the fallback")
            case ("org.gnome.desktop.interface", "text-scaling-factor"):
                return message.reply { $0.variant(signature: "d") { $0.double(1.75) } }
            default:
                return message.replyError(
                    name: "org.freedesktop.portal.Error.NotFound",
                    message: "unknown fixture setting")
            }
        }
        defer { registration.cancel() }

        var snapshot: DesktopPortalSettings?
        let request = try client.readDesktopPortalSettings(
            service: service, path: path, interface: interface
        ) { snapshot = $0 }
        #expect(snapshot == nil, "queueing the batch never blocks for replies")

        for _ in 0..<100 where snapshot == nil {
            _ = try server.process()
            _ = try client.process()
        }
        #expect(snapshot == DesktopPortalSettings(
            colorScheme: 2,
            contrast: 1,
            reducesMotion: true,
            animationsEnabled: false,
            reducesTransparency: true,
            textScale: 1.75))
        #expect(request.isFinished)
    }

    @Test func cancellingAQueuedPortalSnapshotSuppressesItsCompletion() throws {
        guard let client = connect(.session),
              let server = try? SDBusConnection(.session),
              let service = server.uniqueName
        else { return }
        let path = "/org/nucleus/TestPortalCancellation"
        let registration = try server.registerFallback(path: path) { message in
            guard message.readString() != nil, message.readString() != nil else {
                return message.replyError(
                    name: "org.freedesktop.DBus.Error.InvalidArgs",
                    message: "invalid fixture call")
            }
            return message.reply { $0.variant(signature: "u") { $0.uint32(1) } }
        }
        defer { registration.cancel() }

        var completed = false
        let request = try client.readDesktopPortalSettings(
            service: service,
            path: path,
            interface: "org.nucleus.TestPortal.Settings"
        ) { _ in completed = true }
        request.cancel()
        request.cancel()
        for _ in 0..<20 {
            _ = try server.process()
            _ = try client.process()
        }
        #expect(request.isFinished)
        #expect(!completed)
    }

    /// A widget for a service that is not running must render as unavailable
    /// rather than as an error, so this classification is load-bearing.
    @Test func serviceUnavailableIsDistinctFromOtherFailures() {
        let absent = DBusError(
            name: "org.freedesktop.DBus.Error.ServiceUnknown", message: "")
        let noOwner = DBusError(
            name: "org.freedesktop.DBus.Error.NameHasNoOwner", message: "")
        let refused = DBusError(
            name: "org.freedesktop.DBus.Error.AccessDenied", message: "")

        #expect(absent.isServiceUnavailable)
        #expect(noOwner.isServiceUnavailable)
        #expect(!refused.isServiceUnavailable, "denied is not absent")
    }

    // MARK: - Signals

    @Test func aSubscriptionInstallsAndCancels() throws {
        guard let connection = connect(.session) else { return }
        let subscription = try connection.subscribe(
            matching: DBusConnection.propertiesChangedRule(
                service: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus")) { }

        connection.cancel(subscription)
        #expect(subscription.isCancelled)
        // Cancelling twice is harmless.
        connection.cancel(subscription)
        subscription.cancel()
    }

    /// A malformed rule is refused by the bus rather than silently ignored,
    /// which is what stops a typo becoming a signal that never arrives.
    @Test func aMalformedMatchRuleIsRejected() throws {
        guard let connection = connect(.session) else { return }
        #expect(throws: DBusError.self) {
            try connection.subscribe(matching: "this is not a match rule") { }
        }
    }

    /// A real signal arrives and reaches the handler. `NameOwnerChanged` fires
    /// whenever anything joins the bus, so opening a second connection provokes
    /// one without needing a cooperating peer.
    @Test func aSubscribedSignalReachesItsHandler() throws {
        guard let connection = connect(.session) else { return }
        var fired = 0
        let subscription = try connection.subscribe(
            matching: nameOwnerChangedRule
        ) { fired += 1 }
        defer { subscription.cancel() }
        _ = try connection.process()

        // A second connection claims a unique name, which the daemon announces.
        let provoker = connect(.session)
        #expect(provoker != nil)
        _ = try? provoker?.propertyString(
            service: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus", member: "Id")
        provoker?.close()

        // Pump until the announcement lands, bounded so a bus that never sends
        // one fails the expectation rather than hanging.
        for _ in 0..<50 where fired == 0 {
            _ = try connection.process()
        }
        #expect(fired > 0, "the signal reached the handler")
    }

    @Test func cancellingSynchronouslyStopsMatchingSignals() throws {
        guard let connection = connect(.session) else { return }
        var fired = 0
        let subscription = try connection.subscribe(
            matching: nameOwnerChangedRule
        ) { fired += 1 }
        _ = try connection.process()

        let firstProvoker = connect(.session)
        guard firstProvoker != nil else { return }
        _ = try? firstProvoker?.propertyString(
            service: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            member: "Id")
        try pump(connection) { fired > 0 }
        #expect(fired > 0, "the live subscription receives a matching signal")

        subscription.cancel()
        let deliveredBeforeCancellation = fired
        firstProvoker?.close()
        let secondProvoker = connect(.session)
        _ = try? secondProvoker?.propertyString(
            service: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            member: "Id")
        secondProvoker?.close()
        try pump(connection)
        #expect(fired == deliveredBeforeCancellation)
    }

    @Test func droppingTheTokenSynchronouslyStopsMatchingSignals() throws {
        guard let connection = connect(.session) else { return }
        var fired = 0
        var subscription: DBusSubscription? = try connection.subscribe(
            matching: nameOwnerChangedRule
        ) { fired += 1 }
        #expect(subscription != nil)
        _ = try connection.process()

        let deliveredBeforeDrop = fired
        subscription = nil
        let provoker = connect(.session)
        provoker?.close()
        try pump(connection)
        #expect(fired == deliveredBeforeDrop)
    }

    @Test func closeCancelsEveryLiveTokenAndLaterCancellationIsHarmless() throws {
        guard let connection = connect(.session) else { return }
        let first = try connection.subscribe(
            matching: nameOwnerChangedRule
        ) {}
        let second = try connection.subscribe(
            matching: nameOwnerChangedRule
        ) {}

        connection.close()
        #expect(first.isCancelled)
        #expect(second.isCancelled)
        first.cancel()
        second.cancel()
        connection.cancel(first)
        connection.cancel(second)
    }

    // MARK: - Match rules

    @Test func thePropertiesChangedRuleIsWellFormed() {
        let rule = DBusConnection.propertiesChangedRule(
            service: "org.freedesktop.UPower",
            path: "/org/freedesktop/UPower/devices/DisplayDevice",
            interface: "org.freedesktop.UPower.Device")

        #expect(rule.contains("type='signal'"))
        #expect(rule.contains("interface='org.freedesktop.DBus.Properties'"))
        #expect(rule.contains("member='PropertiesChanged'"))
        // arg0 is what keeps one object's signals from waking every observer of
        // every other interface on it.
        #expect(rule.contains("arg0='org.freedesktop.UPower.Device'"))
        #expect(!rule.contains(" "), "no stray whitespace the daemon would reject")
    }
}
