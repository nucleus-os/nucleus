public import NucleusLinuxDBus
public import NucleusLinuxReactor
public import NucleusUI
#if canImport(Glibc)
import Glibc
#endif

public typealias PortalEnvironmentSettings = DesktopPortalSettings

extension DesktopPortalSettings {
    public func normalized(
        fallback: UIEnvironment = UIEnvironment()
    ) -> UIEnvironment {
        UIEnvironment(
            reducesMotion:
                reducesMotion
                ?? animationsEnabled.map(!)
                ?? fallback.reducesMotion,
            reducesTransparency:
                reducesTransparency ?? fallback.reducesTransparency,
            increasesContrast:
                contrast.map { $0 == 1 } ?? fallback.increasesContrast,
            appearance: colorScheme.map { $0 == 2 ? .light : .dark }
                ?? fallback.appearance,
            textScale: textScale ?? fallback.textScale)
    }
}

/// Session-bus owner for the normalized Linux desktop environment.
///
/// It owns one connection, one match slot, and at most one asynchronous refresh
/// batch. Transport failure cancels all three before bounded reconnection. Both
/// the compositor and out-of-process shell drive this same concrete owner from
/// their existing reactors.
@MainActor
public final class PortalEnvironmentAdapter: LinuxReactorSource {
    public static let service = DesktopPortalSettingsEndpoint.service
    public static let path = DesktopPortalSettingsEndpoint.path
    public static let interface = DesktopPortalSettingsEndpoint.interface

    public private(set) var environment: UIEnvironment
    public var onChange: (@MainActor (UIEnvironment) -> Void)?

    private var connection: DBusConnection?
    private var subscription: DBusSubscription?
    private var refreshRequest: DesktopPortalSettingsRequest?
    private var stopped = true
    private var reconnectDeadlineNanoseconds: UInt64?
    private var reconnectDelayNanoseconds: UInt64 = 100_000_000
    private let connectionFactory:
        @MainActor () throws(DBusError) -> DBusConnection
    private let nowNanoseconds: @MainActor () -> UInt64

    public init(environment: UIEnvironment = UIEnvironment()) {
        self.environment = environment
        self.connectionFactory = {
            () throws(DBusError) -> DBusConnection in
            try DBusConnection(.session)
        }
        self.nowNanoseconds = Self.monotonicNowNanoseconds
    }

    package init(
        environment: UIEnvironment = UIEnvironment(),
        connectionFactory:
            @escaping @MainActor () throws(DBusError) -> DBusConnection,
        nowNanoseconds: @escaping @MainActor () -> UInt64
    ) {
        self.environment = environment
        self.connectionFactory = connectionFactory
        self.nowNanoseconds = nowNanoseconds
    }

    @discardableResult
    public func start() -> UIEnvironment {
        stopTransport()
        stopped = false
        reconnectDeadlineNanoseconds = nil
        reconnectDelayNanoseconds = 100_000_000
        attemptConnect()
        return environment
    }

    public func stop() {
        stopped = true
        reconnectDeadlineNanoseconds = nil
        stopTransport()
        onChange = nil
    }

    public var fileDescriptor: Int32 {
        connection?.fileDescriptor ?? -1
    }

    public var pollEvents: Int16 {
        connection?.pollEvents ?? 0
    }

    public func timeoutMicroseconds() -> UInt64? {
        if let connection {
            return connection.timeoutMicroseconds()
        }
        guard !stopped, let deadline = reconnectDeadlineNanoseconds
        else { return nil }
        let now = nowNanoseconds()
        return deadline > now ? (deadline - now) / 1_000 : 0
    }

    @discardableResult
    public func process() -> Bool {
        guard !stopped else { return false }
        if let connection {
            do {
                return try connection.process()
            } catch {
                transportDidFail(
                    operation: "processing desktop settings portal")
                return true
            }
        }
        guard reconnectDeadlineNanoseconds.map({
            nowNanoseconds() >= $0
        }) ?? true else {
            return false
        }
        attemptConnect()
        return connection != nil
    }

    public func transportDidFail(operation: String) {
        guard !stopped else { return }
        stopTransport()
        scheduleReconnect()
    }

    public func refresh() {
        guard let connection else { return }
        refreshRequest?.cancel()
        do {
            refreshRequest = try connection.readDesktopPortalSettings {
                [weak self] settings in
                self?.apply(settings)
            }
        } catch {
            transportDidFail(
                operation: "queueing desktop settings portal read")
        }
    }

    package var hasSubscription: Bool {
        subscription != nil
    }

    private func apply(_ settings: DesktopPortalSettings) {
        let next = settings.normalized(fallback: environment)
        guard next != environment else { return }
        environment = next
        onChange?(next)
    }

    private func attemptConnect() {
        guard !stopped, connection == nil else { return }
        do {
            let connection = try connectionFactory()
            let subscription = try connection.subscribe(
                matching: """
                type='signal',\
                sender='\(Self.service)',\
                path='\(Self.path)',\
                interface='\(Self.interface)',\
                member='\(DesktopPortalSettingsEndpoint.settingChanged)'
                """
            ) { [weak self] in
                self?.refresh()
            }
            self.connection = connection
            self.subscription = subscription
            reconnectDeadlineNanoseconds = nil
            reconnectDelayNanoseconds = 100_000_000
            refresh()
        } catch {
            stopTransport()
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let now = nowNanoseconds()
        let addition = now.addingReportingOverflow(
            reconnectDelayNanoseconds)
        reconnectDeadlineNanoseconds = addition.overflow
            ? UInt64.max : addition.partialValue
        reconnectDelayNanoseconds = min(
            reconnectDelayNanoseconds &* 2,
            5_000_000_000)
    }

    private func stopTransport() {
        refreshRequest?.cancel()
        refreshRequest = nil
        if let subscription, let connection {
            connection.cancel(subscription)
        } else {
            subscription?.cancel()
        }
        subscription = nil
        connection?.close()
        connection = nil
    }

    private static func monotonicNowNanoseconds() -> UInt64 {
        var time = timespec()
        // `time` is a live, correctly aligned value for the duration of the C
        // call, and clock_gettime writes exactly one initialized timespec.
        let result = unsafe clock_gettime(CLOCK_MONOTONIC, &time)
        precondition(result == 0, "CLOCK_MONOTONIC is unavailable")
        let seconds = UInt64(max(0, time.tv_sec))
        let nanoseconds = UInt64(max(0, time.tv_nsec))
        let multiplied = seconds.multipliedReportingOverflow(
            by: 1_000_000_000)
        guard !multiplied.overflow else { return .max }
        let added = multiplied.partialValue.addingReportingOverflow(
            nanoseconds)
        return added.overflow ? .max : added.partialValue
    }
}
