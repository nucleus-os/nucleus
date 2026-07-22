@_spi(NucleusPlatform) public import NucleusRenderer
import NucleusRenderModel
import NucleusShellLoop
import Tracy
#if canImport(Glibc)
import Glibc
#endif

// Owns the shared render core and one Vulkan-WSI presenter per shell surface, and drives the
// per-frame record/present. Mirrors the Android host's AndroidRenderEngine, generalized to N
// surfaces: each shell panel (bar, dock, lock, …) is its own presentable output with its own
// swapchain, all sharing one RenderCore (one VkDevice — Skia can only draw into swapchain
// images on the device that owns them).
//
// Native WindowScene publication commits into the engine-owned store through
// the runtime's RenderCommitSink. Each frame the engine ticks animations, then calls
// RenderCore.renderReady per presenter, which composites the retained tree into that surface's
// acquired swapchain image and presents it.

package enum ShellImageResidency: Sendable, Equatable {
    case unknown
    case pending
    case resident
    case failed
}

@MainActor
public final class ShellRenderEngine {
    public let core: RenderCore
    private var presenters: [UInt64: SwapchainPresenter] = [:]
    // Keyed alongside the presenters: the wl_surface each presents onto, so a resize can
    // re-supply the makeSurface closure (a no-op after first create, which caches the surface).
    private var surfaces: [UInt64: OpaquePointer] = [:]
    private var refreshMillihertzByOutput: [UInt64: Int32] = [:]
    private let display: OpaquePointer
    private var nextOutputID: UInt64 = 1
    private var startupFrameDiagnosticsRemaining = 8

    public init?(
        display: OpaquePointer,
        enableValidation: Bool = false,
        store: RetainedTreeStore,
        resourceHost: SwiftResourceHost,
        asyncRenderWakeSink: any AsyncRenderWakeSink
    ) {
        // The client presentation device: VK_KHR_surface + VK_KHR_wayland_surface (instance)
        // and VK_KHR_swapchain (device). Selected via the core's presentation mode (the core
        // enablement change — otherwise a non-Android Linux process builds the DRM/dmabuf set).
        guard let bootstrap = VulkanBootstrap.create(
            applicationName: "Nucleus Shell",
            presentation: .waylandClientWSI,
            enableValidation: enableValidation),
              let core = RenderCore.create(
            bootstrap: bootstrap,
            qualification: .platformProbe({ instance, physicalDevice, queueFamily in
                WaylandVulkanSurface.supportsPresentation(
                    instance: instance, physicalDevice: physicalDevice,
                    queueFamily: queueFamily, display: display)
            }),
            store: store,
            resourceHost: resourceHost,
            asyncRenderWakeSink: asyncRenderWakeSink
        ) else { return nil }
        self.core = core
        self.display = display
    }

    /// Register a shell surface as a presentable output and build its swapchain presenter.
    /// Returns the assigned output id (used for geometry + per-frame damage). Call once per
    /// surface, after its first layer-shell `configure` reports a size.
    @discardableResult
    public func addSurface(waylandSurface: OpaquePointer, width: Int32, height: Int32,
                           scale: Double, presentationContextID: UInt32,
                           refreshMillihertz: Int32) -> UInt64? {
        let id = nextOutputID
        nextOutputID &+= 1
        let display = self.display
        Self.log(
            "shell-render: add surface output=\(id) extent=\(width)x\(height)")
        guard let surface = core.createSurface({
            WaylandVulkanSurface.make(instance: $0, display: display, surface: waylandSurface)
        }) else {
            Self.log("shell-render: output=\(id) Vulkan surface creation failed")
            return nil
        }
        Self.log("shell-render: output=\(id) Vulkan surface ready")
        guard let presenter = SwapchainPresenter(
            core: core,
            outputID: id,
            surface: surface)
        else {
            Self.log("shell-render: output=\(id) presenter creation failed")
            return nil
        }
        Self.log("shell-render: output=\(id) configuring swapchain")
        guard presenter.configure(
            width: width,
            height: height,
            hasAlpha: true)
        else {
            Self.log(
                "shell-render: output=\(id) swapchain configuration failed "
                    + "status=\(presenter.lastStatus)")
            presenter.teardown()
            return nil
        }
        Self.log(
            "shell-render: output=\(id) swapchain ready "
                + "extent=\(presenter.lastExtentWidth)x"
                + "\(presenter.lastExtentHeight)")
        presenters[id] = presenter
        surfaces[id] = waylandSurface
        refreshMillihertzByOutput[id] = refreshMillihertz
        core.attachOutputGeometry(
            outputID: id, logicalX: 0, logicalY: 0,
            logicalWidth: Double(presenter.lastExtentWidth) / scale,
            logicalHeight: Double(presenter.lastExtentHeight) / scale,
            pixelWidth: UInt32(max(0, presenter.lastExtentWidth)),
            pixelHeight: UInt32(max(0, presenter.lastExtentHeight)),
            fractionalScale: scale)
        core.setOutputRootContexts(
            outputID: id,
            contextIDs: [presentationContextID]
        )
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
        refreshMillihertzByOutput[id] = nil
        core.detachOutputGeometry(outputID: id)
    }

    public func setRefreshMillihertz(_ value: Int32, forSurface id: UInt64) {
        guard presenters[id] != nil else { return }
        refreshMillihertzByOutput[id] = max(0, value)
    }

    /// Pace shared render turns to the fastest active presentation target.
    public var presentationIntervalNanoseconds: UInt64 {
        let interval = refreshMillihertzByOutput.values
            .compactMap {
                ShellPresentationTiming.intervalNanoseconds(
                    refreshMillihertz: $0)
            }
            .min()
        // wl_output supplies a current mode before normal surface
        // configuration. Keep a fail-safe interval for incomplete compositors.
        return interval ?? 16_666_666
    }

    /// Advance animations and render every dirty surface for this frame's predicted present.
    @discardableResult
    public func renderFrame(presentTimeNs: UInt64) -> Set<UInt64> {
        Trace.zone("shell.renderer.frame", color: Trace.Color.green) {
            if startupFrameDiagnosticsRemaining > 0 {
                Self.log(
                    "shell-render: frame begin presenters=\(presenters.count) "
                        + "revision=\(core.store.revision) "
                        + "damage=\(core.store.hasPendingDamage)")
            }
            core.store.tick(presentTimeNs: presentTimeNs)
            var postedOutputIDs = Set<UInt64>()
            for (outputID, presenter) in presenters {
                if core.renderReady(backend: presenter) {
                    postedOutputIDs.insert(outputID)
                }
            }
            if startupFrameDiagnosticsRemaining > 0 {
                startupFrameDiagnosticsRemaining -= 1
                Self.log(
                    "shell-render: frame end posted_outputs="
                        + "\(postedOutputIDs.sorted())")
            }
            return postedOutputIDs
        }
    }

    package func imageResidency(
        for handle: UInt64
    ) -> ShellImageResidency {
        switch core.imageResidency(for: handle) {
        case .unknown: .unknown
        case .pending: .pending
        case .resident: .resident
        case .failed: .failed
        }
    }

    private static func log(_ message: String) {
        #if canImport(Glibc)
        let line = message + "\n"
        line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
        #endif
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
