public import NucleusLinuxDBus

/// What UPower reports a battery is doing. Values match
/// `org.freedesktop.UPower.Device.State`.
public enum BatteryChargeState: UInt32, Sendable, Equatable {
    case unknown = 0
    case charging = 1
    case discharging = 2
    case empty = 3
    case fullyCharged = 4
    case pendingCharge = 5
    case pendingDischarge = 6

    /// Whether power is going in. `pendingCharge` counts: the machine is
    /// plugged in and the battery is simply not taking charge yet, which reads
    /// to a user as charging rather than as draining.
    public var isPluggedIn: Bool {
        self == .charging || self == .fullyCharged || self == .pendingCharge
    }
}

/// One reading of the aggregate battery.
public struct BatteryReading: Sendable, Equatable {
    /// Whether there is a battery at all. A desktop reports a display device
    /// that is not present, which is not an error and not zero percent.
    public var isPresent: Bool
    /// 0...100, as UPower reports it.
    public var percentage: Double
    public var state: BatteryChargeState
    /// Seconds until empty while discharging, or 0 when unknown.
    public var timeToEmptySeconds: Int64
    /// Seconds until full while charging, or 0 when unknown.
    public var timeToFullSeconds: Int64

    public init(
        isPresent: Bool = false,
        percentage: Double = 0,
        state: BatteryChargeState = .unknown,
        timeToEmptySeconds: Int64 = 0,
        timeToFullSeconds: Int64 = 0
    ) {
        self.isPresent = isPresent
        self.percentage = percentage
        self.state = state
        self.timeToEmptySeconds = timeToEmptySeconds
        self.timeToFullSeconds = timeToFullSeconds
    }

    /// Seconds until the battery reaches its destination, or `nil` when UPower
    /// has not worked it out — which it has not for the first minute or so after
    /// a state change, and never on a desktop.
    public var secondsRemaining: Int64? {
        let value = state.isPluggedIn ? timeToFullSeconds : timeToEmptySeconds
        return value > 0 ? value : nil
    }
}

/// Reads the aggregate battery from UPower and reports changes.
///
/// UPower publishes a `DisplayDevice` that already aggregates every battery on
/// the machine, which is exactly what a bar widget wants — a laptop with two
/// batteries should show one figure, and picking a device is policy the service
/// has no business inventing.
///
/// Lives on the **system** bus. Absence is a normal outcome: a machine can have
/// no UPower, or UPower with no battery, and neither is a failure to report as
/// one.
@MainActor
public final class UPowerService {
    public static let serviceName = "org.freedesktop.UPower"
    public static let displayDevicePath = "/org/freedesktop/UPower/devices/DisplayDevice"
    public static let deviceInterface = "org.freedesktop.UPower.Device"

    /// The most recent reading, or `nil` before the first successful read.
    public private(set) var reading: BatteryReading?

    /// Whether UPower answered at all. `false` means no service on the bus —
    /// render as absent, not as broken.
    public private(set) var isAvailable = false

    /// Called after each successful read, including the first.
    public var onChange: ((BatteryReading) -> Void)?

    private let connection: DBusConnection
    private var subscription: DBusSubscription?

    public init(connection: DBusConnection) {
        self.connection = connection
    }

    /// Subscribe to changes and take the first reading.
    ///
    /// Does not throw when UPower is absent: that is a configuration, not an
    /// error, and a caller that treated it as one would have to special-case the
    /// most ordinary failure. It throws only when the *bus* misbehaves.
    public func start() throws(DBusError) {
        subscription = try connection.subscribe(
            matching: DBusConnection.propertiesChangedRule(
                service: UPowerService.serviceName,
                path: UPowerService.displayDevicePath,
                interface: UPowerService.deviceInterface)
        ) { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    public func stop() {
        if let subscription { connection.cancel(subscription) }
        subscription = nil
    }

    /// Re-read every property the widget displays.
    ///
    /// The whole read, not a delta: `PropertiesChanged` says something moved,
    /// and re-reading the handful of values shown is both simpler and more
    /// correct than trusting a payload that may list a property as merely
    /// invalidated.
    public func refresh() {
        do {
            let reading = try read()
            isAvailable = true
            if reading != self.reading {
                self.reading = reading
                onChange?(reading)
            }
        } catch let error {
            if error.isServiceUnavailable {
                // No UPower on this machine. Report absence once and stop
                // pretending there is a battery.
                isAvailable = false
                if reading != nil || !hasReportedAbsence {
                    hasReportedAbsence = true
                    reading = BatteryReading(isPresent: false)
                    onChange?(BatteryReading(isPresent: false))
                }
            }
            // Any other failure leaves the last good reading in place: a
            // transient bus error should not blank a widget that was working.
        }
    }

    private var hasReportedAbsence = false

    private func read() throws(DBusError) -> BatteryReading {
        let isPresent = try connection.propertyBool(
            service: UPowerService.serviceName,
            path: UPowerService.displayDevicePath,
            interface: UPowerService.deviceInterface,
            member: "IsPresent")
        guard isPresent else { return BatteryReading(isPresent: false) }

        return BatteryReading(
            isPresent: true,
            percentage: try connection.propertyDouble(
                service: UPowerService.serviceName,
                path: UPowerService.displayDevicePath,
                interface: UPowerService.deviceInterface,
                member: "Percentage"),
            state: BatteryChargeState(
                rawValue: try connection.propertyUInt32(
                    service: UPowerService.serviceName,
                    path: UPowerService.displayDevicePath,
                    interface: UPowerService.deviceInterface,
                    member: "State")) ?? .unknown,
            timeToEmptySeconds: try connection.propertyInt64(
                service: UPowerService.serviceName,
                path: UPowerService.displayDevicePath,
                interface: UPowerService.deviceInterface,
                member: "TimeToEmpty"),
            timeToFullSeconds: try connection.propertyInt64(
                service: UPowerService.serviceName,
                path: UPowerService.displayDevicePath,
                interface: UPowerService.deviceInterface,
                member: "TimeToFull"))
    }
}
