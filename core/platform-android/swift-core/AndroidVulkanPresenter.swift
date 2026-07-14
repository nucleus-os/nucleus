internal import VulkanC
internal import NucleusRenderer

// The Android presentation backend — a thin adapter over the shared `SwapchainPresenter`
// (in NucleusRenderer). Android surface creation and physical-device qualification happen
// during render-engine bootstrap; this adapter supplies only opaque composite alpha. All the
// swapchain machinery (create/acquire/present/recreate and teardown) lives
// once in `SwapchainPresenter`, shared with the Nucleus shell's Wayland client. It conforms to
// `PresentationBackend` by forwarding to the shared presenter, and maps the shared
// `SwapchainStatus` to the JNI-boundary `RenderStatus`.
//
// Runtime behaviour is device/emulator-gated (deferred hardware validation); this lands
// build-verified (compiles, links, WSI + render-core symbols resolve).
@MainActor
final class AndroidVulkanPresenter: PresentationBackend {
    // The single Android output id (one ANativeWindow surface).
    static let outputID: UInt64 = 1

    private let swapchain: SwapchainPresenter
    /// Build over the render core's device. The core's instance must enable
    /// `VK_KHR_surface` + `VK_KHR_android_surface` and its device `VK_KHR_swapchain`
    /// + `VK_KHR_swapchain_maintenance1`
    /// (`VkRequirements` `#if os(Android)`).
    init?(core: RenderCore, surface: VulkanSurface) {
        guard let swapchain = SwapchainPresenter(
                  core: core, outputID: Self.outputID, surface: surface)
        else {
            return nil
        }
        self.swapchain = swapchain
    }

    isolated deinit { swapchain.teardown() }

    func teardown() { swapchain.teardown() }

    var lastExtentWidth: Int32 { swapchain.lastExtentWidth }
    var lastExtentHeight: Int32 { swapchain.lastExtentHeight }
    var lastStatus: RenderStatus { Self.map(swapchain.lastStatus) }

    /// (Re)create the swapchain for the drawable size. Android surfaces are opaque here.
    @discardableResult
    func configure(width: Int32, height: Int32) -> Bool {
        swapchain.configure(width: width, height: height, hasAlpha: false)
    }

    // MARK: PresentationBackend — forwarded to the shared presenter.
    func presentableOutputIDs() -> [UInt64] { swapchain.presentableOutputIDs() }
    func isReadyToPresent(_ outputID: UInt64) -> Bool { swapchain.isReadyToPresent(outputID) }
    func acquireTarget(_ outputID: UInt64) -> AcquiredFrameTarget? { swapchain.acquireTarget(outputID) }
    func didSubmitTarget(_ outputID: UInt64) -> Bool { swapchain.didSubmitTarget(outputID) }
    func present(_ outputID: UInt64) -> Bool { swapchain.present(outputID) }
    func discardAcquiredTarget(_ outputID: UInt64) { swapchain.discardAcquiredTarget(outputID) }
    func didPresentFrame() { swapchain.didPresentFrame() }
    func pauseSession() { swapchain.pauseSession() }
    func resumeSession() { swapchain.resumeSession() }

    private static func map(_ s: SwapchainStatus) -> RenderStatus {
        switch s {
        case .none: return .none
        case .posted: return .posted
        case .noSurface: return .no_surface
        case .invalidSurface: return .invalid_surface
        case .recreated: return .recreated
        case .acquireFailed: return .acquire_failed
        case .renderFailed: return .render_failed
        case .presentFailed: return .present_failed
        }
    }
}
