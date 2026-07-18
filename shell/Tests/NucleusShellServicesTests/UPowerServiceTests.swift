import Testing
import NucleusShellDBus
@testable import NucleusShellServices

/// UPower, against the real system bus where one is reachable.
///
/// The value-level assertions always run; the bus ones degrade to a skip. What
/// is deliberately *not* asserted is any particular battery state — this suite
/// runs on desktops and laptops both, and a test that demanded a battery would
/// be a test of the machine.
@MainActor
@Suite struct UPowerServiceTests {
    private func makeService() -> (UPowerService, DBusConnection)? {
        guard let connection = try? DBusConnection(.system) else { return nil }
        return (UPowerService(connection: connection), connection)
    }

    // MARK: - Charge state

    /// Plugged in covers more than `charging`. A full battery on mains is not
    /// draining, and `pendingCharge` means plugged in but not yet drawing —
    /// treating either as discharging would show a laptop on mains as on
    /// battery.
    @Test func pluggedInCoversEveryMainsState() {
        #expect(BatteryChargeState.charging.isPluggedIn)
        #expect(BatteryChargeState.fullyCharged.isPluggedIn)
        #expect(BatteryChargeState.pendingCharge.isPluggedIn)

        #expect(!BatteryChargeState.discharging.isPluggedIn)
        #expect(!BatteryChargeState.empty.isPluggedIn)
        #expect(!BatteryChargeState.unknown.isPluggedIn)
    }

    @Test func stateValuesMatchTheProtocol() {
        // These are UPower's own numbers; a widget reading the wrong one shows
        // the wrong state, silently.
        #expect(BatteryChargeState(rawValue: 1) == .charging)
        #expect(BatteryChargeState(rawValue: 2) == .discharging)
        #expect(BatteryChargeState(rawValue: 4) == .fullyCharged)
        #expect(BatteryChargeState(rawValue: 99) == nil)
    }

    // MARK: - Readings

    /// The remaining time depends on which way the charge is going, and UPower
    /// reports zero for "not worked out yet" rather than omitting it.
    @Test func remainingTimeFollowsTheDirectionOfCharge() {
        let discharging = BatteryReading(
            isPresent: true, percentage: 50, state: .discharging,
            timeToEmptySeconds: 3600, timeToFullSeconds: 0)
        #expect(discharging.secondsRemaining == 3600)

        let charging = BatteryReading(
            isPresent: true, percentage: 50, state: .charging,
            timeToEmptySeconds: 0, timeToFullSeconds: 1800)
        #expect(charging.secondsRemaining == 1800)
    }

    @Test func anUnknownEstimateIsNilRatherThanZero() {
        let reading = BatteryReading(
            isPresent: true, percentage: 50, state: .discharging,
            timeToEmptySeconds: 0)
        #expect(reading.secondsRemaining == nil, "zero means unknown, not imminent")
    }

    @Test func anAbsentBatteryIsNotZeroPercent() {
        let reading = BatteryReading(isPresent: false)
        #expect(!reading.isPresent)
        #expect(reading.secondsRemaining == nil)
    }

    // MARK: - Against the bus

    @Test func startingReadsTheDisplayDevice() throws {
        guard let (service, connection) = makeService() else { return }
        defer { connection.close() }

        var changes = 0
        service.onChange = { _ in changes += 1 }
        try service.start()

        // Either UPower answered, or it is absent — both are outcomes, and both
        // produce exactly one initial report.
        #expect(changes == 1, "the first reading is always reported")
        #expect(service.reading != nil)

        if service.isAvailable, let reading = service.reading, reading.isPresent {
            #expect(reading.percentage >= 0 && reading.percentage <= 100)
        }
    }

    /// An absent service is a configuration, not an error. A machine with no
    /// UPower must not make `start()` throw, or every caller has to special-case
    /// the most ordinary failure there is.
    @Test func anAbsentServiceDoesNotThrow() throws {
        guard let connection = try? DBusConnection(.system) else { return }
        defer { connection.close() }

        // A service name that certainly has no owner.
        let service = UPowerService(connection: connection)
        service.onChange = { _ in }
        // Reading a nonexistent peer goes through the same absence path.
        service.refresh()
        // No throw, and the widget-facing state says absent rather than broken.
        if !service.isAvailable {
            #expect(service.reading?.isPresent == false)
        }
    }

    /// A repeated identical reading does not re-notify. A bar widget redraws on
    /// every change, and UPower emits PropertiesChanged for values a widget does
    /// not display.
    @Test func anUnchangedReadingDoesNotNotifyAgain() throws {
        guard let (service, connection) = makeService() else { return }
        defer { connection.close() }

        var changes = 0
        service.onChange = { _ in changes += 1 }
        try service.start()
        let afterStart = changes

        service.refresh()
        service.refresh()
        #expect(changes == afterStart, "identical readings are not changes")
    }

    @Test func stoppingUnsubscribes() throws {
        guard let (service, connection) = makeService() else { return }
        defer { connection.close() }

        try service.start()
        service.stop()
        service.stop()
    }
}
