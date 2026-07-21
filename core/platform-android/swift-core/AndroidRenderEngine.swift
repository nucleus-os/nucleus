// The Android render engine: the `@MainActor` owner of the shared render stack on
// Android. It holds the platform-agnostic `RenderCore` (Vulkan instance/device +
// Graphite context + the retained NucleusUI tree) and the `AndroidVulkanPresenter`
// (the `PresentationBackend` over an ANativeWindow swapchain on the core's device),
// and drives one frame: tick animations, then `RenderCore.renderReady(backend:)`
// records the retained tree into the acquired swapchain image (Skia Vulkan
// Graphite) and presents it. When the tree has no pending damage (e.g. before any
// content mounts) the render core forces one initial Graphite frame so the surface
// is defined without a second Vulkan submission pipeline.
//
// `AndroidRenderer` (a value type on the JNI thread) holds this by reference and
// calls it through `MainActor.assumeIsolated` — the render path is main-actor
// isolated like the compositor's (the retained store + layers commit sink are).
// The thread the JNI frame callback runs on is treated as the main actor; that
// binding is part of the deferred on-device validation.

@_spi(NucleusPlatform) internal import NucleusRenderer
internal import VulkanC

@MainActor
final class AndroidRenderEngine {
    private let core: RenderCore
    private let presenter: AndroidVulkanPresenter
    /// Surface generation the swapchain was last configured for; .max = unconfigured.
    private var configuredGeneration: UInt64 = .max

    var lastExtentWidth: Int32 { presenter.lastExtentWidth }
    var lastExtentHeight: Int32 { presenter.lastExtentHeight }
    var lastStatus: RenderStatus { presenter.lastStatus }

    /// Bring up the render core (Vulkan instance/device + Graphite context) and the
    /// swapchain presenter over its device. Returns nil if the GPU stack is
    /// unavailable.
    init?(
        window: UnsafeMutableRawPointer,
        store: RetainedTreeStore,
        resourceHost: SwiftResourceHost,
        asyncRenderWakeSink: any AsyncRenderWakeSink
    ) {
        guard let bootstrap = VulkanBootstrap.create(applicationName: "Nucleus Android"),
              let surface = bootstrap.createSurface({ context in
            let instance = context.vkInstance
            guard let raw = vkGetInstanceProcAddr(instance, "vkCreateAndroidSurfaceKHR") else {
                return nil
            }
            let create = unsafeBitCast(raw, to: PFN_vkCreateAndroidSurfaceKHR.self)
            var info = VkAndroidSurfaceCreateInfoKHR()
            info.sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR
            info.window = OpaquePointer(window)
            var surface: VkSurfaceKHR? = nil
            guard create(instance, &info, nil, &surface) == VK_SUCCESS, let surface else { return nil }
            return VulkanSurfaceHandle(surface)
        }),
              let core = RenderCore.create(
                bootstrap: bootstrap,
                qualification: .surface(surface),
                store: store,
                resourceHost: resourceHost,
                asyncRenderWakeSink: asyncRenderWakeSink)
        else { return nil }
        guard let presenter = AndroidVulkanPresenter(core: core, surface: surface) else {
            core.shutdownRenderResources()
            core.teardownDevice()
            return nil
        }
        self.core = core
        self.presenter = presenter
    }

    /// Render one frame to the ANativeWindow. (Re)configures the swapchain when the
    /// surface generation changes, advances animations to `frameTimeNanos`, then
    /// records + presents the NucleusUI scene (or clears when there is no damage).
    func frame(
        width: Int32, height: Int32,
        generation: UInt64, frameTimeNanos: Int64
    ) -> RenderStatus {
        if configuredGeneration != generation {
            guard presenter.configure(width: width, height: height) else {
                return presenter.lastStatus
            }
            // Register the output geometry at the swapchain's actual drawable extent
            // (logical == pixels, scale 1 — the host owns no fractional scale yet).
            core.attachOutputGeometry(
                outputID: AndroidVulkanPresenter.outputID,
                logicalX: 0, logicalY: 0,
                logicalWidth: Double(presenter.lastExtentWidth),
                logicalHeight: Double(presenter.lastExtentHeight),
                pixelWidth: UInt32(max(0, presenter.lastExtentWidth)),
                pixelHeight: UInt32(max(0, presenter.lastExtentHeight)),
                fractionalScale: 1)
            configuredGeneration = generation
        }

        core.store.tick(presentTimeNs: UInt64(max(0, frameTimeNanos)))
        if core.renderReady(backend: presenter) { return .posted }
        return .none
    }

    /// Tear down in GPU-lifetime order: the presenter's swapchain/sync objects
    /// (created on the core's device) first, then the core's render resources, then
    /// the core's device. The Graphite context drops when the core deinits.
    func shutdown() {
        presenter.teardown()
        core.shutdownRenderResources()
        core.teardownDevice()
    }
}
