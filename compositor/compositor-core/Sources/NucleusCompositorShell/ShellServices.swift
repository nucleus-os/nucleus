@_exported import NucleusCompositorShellSurface
import NucleusCompositorServer

@MainActor
public final class ShellServices {
    public static let shared = ShellServices()

    public struct ServiceSnapshot: Sendable, Equatable {
        public var dbusServiceCount: Int
        public var hasNotificationService: Bool
        public var hasAppearancePortal: Bool
        public var hasCursorTheme: Bool
        public var hasDataExchangeService: Bool
    }

    public let launcher: LauncherService
    public let notifications: NotificationService
    public let appearance: AppearancePortal
    public let cursors: CursorTheme
    public let screenshots: ScreenshotService
    public let dataExchange: DataExchangeService

    private init() {
        launcher = .shared
        notifications = .shared
        appearance = .shared
        cursors = .shared
        screenshots = .shared
        dataExchange = .shared
    }

    public func serviceSnapshot() -> ServiceSnapshot {
        ServiceSnapshot(
            dbusServiceCount: compositorShellDBusInterfaces.count,
            hasNotificationService: notifications === NotificationService.shared,
            hasAppearancePortal: appearance === AppearancePortal.shared,
            hasCursorTheme: cursors === CursorTheme.shared,
            hasDataExchangeService: dataExchange === DataExchangeService.shared
        )
    }
}
