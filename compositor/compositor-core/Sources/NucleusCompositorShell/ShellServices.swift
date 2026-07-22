import Foundation
import NucleusCompositorOverlayScene
import NucleusCompositorServer
import NucleusCompositorWindowManager
import NucleusLayers
import NucleusLinuxAccessibility
import NucleusLinuxEnvironment
import NucleusUI

/// Compositor-owned shell service graph. Every stateful shell subsystem is
/// constructed here and tied to the lifetime of one compositor runtime.
@MainActor
public final class ShellServices {
    public let overlayScene: OverlaySceneRuntime
    public let notifications: NotificationService
    public let screenshots: ScreenshotService
    public let bezel: BezelService
    public let launcher: LauncherService
    public let idlePolicy: IdlePolicy
    public let cursorTheme: CursorThemeService
    public let keybinds: KeybindService
    public let shellPolicy: ShellPolicyService

    private unowned let server: NucleusCompositorServer
    private let environmentAdapter: PortalEnvironmentAdapter
    private var accessibilityService: AtSPIService?
    private var accessibilityBridge: AtSPIBridge?
    private var publicationHost: ShellOverlayPublicationHost?

    public init(
        server: NucleusCompositorServer,
        windowManager: WindowManager
    ) {
        self.server = server

        let overlayScene = OverlaySceneRuntime(server: server)
        let notifications = NotificationService(overlayScene: overlayScene)
        let launcher = LauncherService()
        let idlePolicy = IdlePolicy()
        let cursorTheme = CursorThemeService(server: server)
        let bezel = BezelService(
            overlayScene: overlayScene,
            notifications: notifications)
        let keybinds = KeybindService(
            launcher: launcher,
            windowManager: windowManager)

        self.overlayScene = overlayScene
        self.notifications = notifications
        self.screenshots = ScreenshotService(notifications: notifications)
        self.bezel = bezel
        self.launcher = launcher
        self.idlePolicy = idlePolicy
        self.cursorTheme = cursorTheme
        self.keybinds = keybinds
        self.shellPolicy = ShellPolicyService(
            keybinds: keybinds,
            launcher: launcher,
            idle: idlePolicy,
            cursorTheme: cursorTheme,
            bezel: bezel,
            notifications: notifications,
            overlayScene: overlayScene)
        self.environmentAdapter = PortalEnvironmentAdapter()
    }

    /// Begin portal discovery only after the compositor has published its
    /// Wayland socket. D-Bus activated portal backends inherit WAYLAND_DISPLAY
    /// from the session daemon and may connect as soon as the first request is
    /// queued.
    public func activateEnvironment() {
        overlayScene.updateEnvironment(environmentAdapter.start())
    }

    public func installOverlay(
        commitSink: any CommitSink,
        services: UIHostServices
    ) -> Bool {
        environmentAdapter.onChange = nil
        let publicationHost = ShellOverlayPublicationHost(
            services: self,
            notifications: notifications,
            server: server)
        self.publicationHost = publicationHost
        guard overlayScene.installHost(
            publicationHost,
            commitSink: commitSink,
            services: services,
            environment: environmentAdapter.environment)
        else {
            self.publicationHost = nil
            return false
        }
        guard installAccessibility() else {
            overlayScene.clearHost()
            self.publicationHost = nil
            return false
        }
        environmentAdapter.onChange = { [weak overlayScene] environment in
            overlayScene?.updateEnvironment(environment)
        }
        return true
    }

    private func installAccessibility() -> Bool {
        accessibilityService?.close()
        accessibilityService = nil
        accessibilityBridge = nil
        do {
            return try overlayScene.withScene { scene in
                let service = AtSPIService(
                    applicationName: "Nucleus Compositor")
                service.diagnosticHandler = { failure, generation in
                    let line = "compositor: AT-SPI generation \(generation) "
                        + "\(failure.operation) failed (\(failure.code))\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                let bridge = AtSPIBridge(
                    scene: scene.windowScene,
                    service: service)
                service.onAction = { [weak bridge] request in
                    bridge?.perform(request) ?? false
                }
                accessibilityService = service
                accessibilityBridge = bridge
                _ = bridge.publish()
                return true
            }
        } catch {
            return false
        }
    }

    func publishAccessibility() {
        _ = accessibilityBridge?.publish()
    }

    public var environmentReactorSource: PortalEnvironmentAdapter {
        environmentAdapter
    }

    public var accessibilityReactorSource: AtSPIService? {
        accessibilityService
    }

    public func shutdown() {
        environmentAdapter.stop()
        accessibilityService?.close()
        accessibilityService = nil
        accessibilityBridge = nil
        publicationHost = nil
        overlayScene.clearHost()
        notifications.reset()
        screenshots.reset()
        server.dataExchange.reset()
    }
}
