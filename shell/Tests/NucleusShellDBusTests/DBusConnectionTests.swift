import Testing
@testable import NucleusShellDBus

/// The D-Bus client seam, against a real bus where one is reachable.
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
        } catch let error as DBusError {
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
        } catch let error as DBusError {
            #expect(error.isServiceUnavailable,
                    "classified as absent, not as broken: \(error.name)")
        }
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
        // Cancelling twice is harmless.
        connection.cancel(subscription)
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
        _ = try connection.subscribe(
            matching: """
            type='signal',\
            sender='org.freedesktop.DBus',\
            interface='org.freedesktop.DBus',\
            member='NameOwnerChanged'
            """) { fired += 1 }
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
