import Foundation
import NucleusCompositorOverlayScene
import NucleusLinuxAccessibility
import NucleusLinuxEnvironment
import NucleusUI
import NucleusLayers

/// Compositor composition owner for shell policy, portal state, and overlay
/// environment propagation.
///
/// This object is retained by `CompositorRuntime`. It deliberately has no
/// process-global instance: its environment subscription and bus resources
/// follow the compositor runtime's acquisition and teardown order.
@MainActor
public final class ShellServices {
    public let shellPolicy: ShellPolicyService

    private let environmentAdapter: PortalEnvironmentAdapter
    private var accessibilityService: AtSPIService?
    private var accessibilityBridge: AtSPIBridge?

    public init() {
        self.shellPolicy = ShellPolicyService()
        self.environmentAdapter = PortalEnvironmentAdapter()
    }

    /// Open the portal and return the current normalized snapshot immediately.
    /// The event loop applies the nonblocking portal reply after installation.
    public func prepareEnvironment() -> UIEnvironment {
        environmentAdapter.start()
    }

    /// Construct the overlay with the already-acquired snapshot, then attach
    /// the sole runtime subscription.
    public func installOverlay(
        commitSink: any CommitSink,
        services: UIHostServices
    ) -> Bool {
        environmentAdapter.onChange = nil
        let installed = nucleus_compositor_overlay_runtime_install_host(
            ShellOverlayPublicationHost(services: self),
            commitSink: commitSink,
            services: services,
            environment: environmentAdapter.environment) != 0
        guard installed else { return false }
        guard installAccessibility() else {
            _ = nucleus_compositor_overlay_runtime_clear_host()
            return false
        }
        environmentAdapter.onChange = {
            environment in
            nucleus_compositor_overlay_scene_update_environment(environment)
        }
        return true
    }

    private func installAccessibility() -> Bool {
        accessibilityService?.close()
        accessibilityService = nil
        accessibilityBridge = nil
        do {
            return try withGlobalShellOverlayScene { scene in
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

    /// Stop environment callbacks before destroying the overlay context, then
    /// release every sd-bus slot and connection.
    public func shutdown() {
        environmentAdapter.stop()
        accessibilityService?.close()
        accessibilityService = nil
        accessibilityBridge = nil
        _ = nucleus_compositor_overlay_runtime_clear_host()
    }
}
