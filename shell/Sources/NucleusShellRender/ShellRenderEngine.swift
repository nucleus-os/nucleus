public import NucleusRenderer

// Owns the shared render core and one Vulkan-WSI presenter per shell surface, and drives the
// per-frame record/present. Mirrors the Android host's AndroidRenderEngine, generalized to N
// surfaces: each shell panel (bar, dock, lock, …) is its own presentable output with its own
// swapchain, all sharing one RenderCore (one VkDevice — Skia can only draw into swapchain
// images on the device that owns them).
//
// The RN runtime commits its layer tree into RetainedTreeStore.shared via RenderCommitSink
// (installed by the runtime). Each frame the engine ticks the store's animations, then calls
// RenderCore.renderReady per presenter, which composites the retained tree into that surface's
// acquired swapchain image and presents it.

@MainActor
public final class ShellRenderEngine {
    public let core: RenderCore
    private var presenters: [UInt64: SwapchainPresenter] = [:]
    // Keyed alongside the presenters: the wl_surface each presents onto, so a resize can
    // re-supply the makeSurface closure (a no-op after first create, which caches the surface).
    private var surfaces: [UInt64: OpaquePointer] = [:]
    private let display: OpaquePointer
    private var nextOutputID: UInt64 = 1

    public init?(display: OpaquePointer) {
        // The client presentation device: VK_KHR_surface + VK_KHR_wayland_surface (instance)
        // and VK_KHR_swapchain (device). Selected via the core's presentation mode (the core
        // enablement change — otherwise a non-Android Linux process builds the DRM/dmabuf set).
        guard let bootstrap = VulkanBootstrap.create(
            applicationName: "Nucleus Shell", presentation: .waylandClientWSI),
              let core = RenderCore.create(
            bootstrap: bootstrap,
            qualification: .platformProbe({ instance, physicalDevice, queueFamily in
                WaylandVulkanSurface.supportsPresentation(
                    instance: instance, physicalDevice: physicalDevice,
                    queueFamily: queueFamily, display: display)
            })
        ) else { return nil }
        self.core = core
        self.display = display
    }

    /// Register a shell surface as a presentable output and build its swapchain presenter.
    /// Returns the assigned output id (used for geometry + per-frame damage). Call once per
    /// surface, after its first layer-shell `configure` reports a size.
    @discardableResult
    public func addSurface(waylandSurface: OpaquePointer, width: Int32, height: Int32,
                           scale: Double) -> UInt64? {
        let id = nextOutputID
        nextOutputID &+= 1
        let display = self.display
        guard let surface = core.createSurface({
            WaylandVulkanSurface.make(instance: $0, display: display, surface: waylandSurface)
        }),
              let presenter = SwapchainPresenter(core: core, outputID: id, surface: surface),
              presenter.configure(width: width, height: height, hasAlpha: true)
        else { return nil }
        presenters[id] = presenter
        surfaces[id] = waylandSurface
        core.attachOutputGeometry(
            outputID: id, logicalX: 0, logicalY: 0,
            logicalWidth: Double(presenter.lastExtentWidth) / scale,
            logicalHeight: Double(presenter.lastExtentHeight) / scale,
            pixelWidth: UInt32(max(0, presenter.lastExtentWidth)),
            pixelHeight: UInt32(max(0, presenter.lastExtentHeight)),
            fractionalScale: scale)
        return id
    }

    /// Place a surface's logical rectangle within the shell's shared logical space.
    ///
    /// `addSurface` and `resizeSurface` both assume the origin, which is right
    /// for a single presentation target. A shell with more than one — a bar and
    /// a lock screen — needs them in disjoint regions, because the render core
    /// composites one logical plane and any two targets whose rectangles overlap
    /// show the same content.
    public func placeSurface(
        _ id: UInt64,
        logicalX: Double, logicalY: Double,
        logicalWidth: Double, logicalHeight: Double,
        scale: Double
    ) {
        guard let presenter = presenters[id] else { return }
        core.attachOutputGeometry(
            outputID: id, logicalX: logicalX, logicalY: logicalY,
            logicalWidth: logicalWidth, logicalHeight: logicalHeight,
            pixelWidth: UInt32(max(0, presenter.lastExtentWidth)),
            pixelHeight: UInt32(max(0, presenter.lastExtentHeight)),
            fractionalScale: scale)
    }

    /// Resize a surface's swapchain (on a subsequent layer-shell `configure`). The surface is
    /// already created — the makeSurface closure is a no-op (SwapchainPresenter caches it).
    public func resizeSurface(_ id: UInt64, width: Int32, height: Int32, scale: Double) {
        guard let presenter = presenters[id] else { return }
        _ = presenter.configure(width: width, height: height, hasAlpha: true)
        core.attachOutputGeometry(
            outputID: id, logicalX: 0, logicalY: 0,
            logicalWidth: Double(presenter.lastExtentWidth) / scale,
            logicalHeight: Double(presenter.lastExtentHeight) / scale,
            pixelWidth: UInt32(max(0, presenter.lastExtentWidth)),
            pixelHeight: UInt32(max(0, presenter.lastExtentHeight)),
            fractionalScale: scale)
    }

    public func removeSurface(_ id: UInt64) {
        presenters[id]?.teardown()
        presenters[id] = nil
        surfaces[id] = nil
        core.detachOutputGeometry(outputID: id)
    }

    /// Advance animations and render every dirty surface for this frame's predicted present.
    @discardableResult
    public func renderFrame(presentTimeNs: UInt64) -> Bool {
        core.store.tick(presentTimeNs: presentTimeNs)
        var posted = false
        for (_, presenter) in presenters {
            if core.renderReady(backend: presenter) { posted = true }
        }
        return posted
    }

    /// Ordered teardown: presenters (their swapchains/surfaces live on the core's device) →
    /// core render resources → device.
    public func shutdown() {
        for (_, p) in presenters { p.teardown() }
        presenters.removeAll()
        core.shutdownRenderResources()
        core.teardownDevice()
    }
}
