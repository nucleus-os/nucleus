@_spi(NucleusPlatform) public import NucleusRenderer
public import NucleusRenderModel
import NucleusDiagnostics
import NucleusWindowClientRuntime
@_spi(NucleusWindowClientImplementation)
import NucleusWindowClientWayland
import Tracy
import WaylandClientDispatch
#if canImport(Glibc)
import Glibc
#endif

// Owns the shared render core and one DMA-BUF presenter per desktop surface, and drives the
// per-frame record/present. Mirrors the Android host's AndroidRenderEngine, generalized to N
// surfaces: each desktop surface (bar, dock, lock, …) is its own presentable output with its own
// swapchain, all sharing one RenderCore (one VkDevice — Skia can only draw into swapchain
// images on the device that owns them).
//
// Native WindowScene publication commits into the engine-owned store through
// the runtime's RenderCommitSink. Each frame the engine ticks animations, then calls
// RenderCore.renderReady per presenter, which composites the retained tree into that surface's
// acquired client backing-store image and commits it.

public enum WindowClientImageResidency: Sendable, Equatable {
    case unknown
    case pending
    case resident
    case failed
}

@MainActor
@safe public final class NucleusWindowClientRenderEngine {
    public let core: RenderCore
    private var presenters:
        [UInt64: WaylandBackingStorePresenter] = [:]
    private var refreshMillihertzByOutput: [UInt64: Int32] = [:]
    private var presentationContextIDByOutput: [UInt64: UInt32] = [:]
    private var presentationRootLayerIDByOutput: [UInt64: UInt64] = [:]
    private let connection: NucleusDesktopConnection
    private var nextOutputID: UInt64 = 1
    private var startupFrameDiagnosticsRemaining = 8
    public private(set) var deviceLost = false

    public init?(
        connection: NucleusDesktopConnection,
        enableValidation: Bool = false,
        store: RetainedTreeStore,
        resourceHost: SwiftResourceHost,
        asyncRenderWakeSink: any AsyncRenderWakeSink
    ) {
        guard let bootstrap = VulkanBootstrap.create(
            applicationName: "Nucleus Window Client",
            presentation: .waylandClientBackingStore,
            enableValidation: enableValidation),
              let core = RenderCore.create(
            bootstrap: bootstrap,
            qualification: .none,
            store: store,
            resourceHost: resourceHost,
            asyncRenderWakeSink: asyncRenderWakeSink
        ) else { return nil }
        self.core = core
        self.connection = connection
    }

    /// Register a shell surface as a presentable output and build its swapchain presenter.
    /// Returns the assigned output id (used for geometry + per-frame damage). Call once per
    /// surface, after its first layer-shell `configure` reports a size.
    @discardableResult
    @_spi(NucleusWindowClientImplementation)
    public func addSurface(
        waylandSurface: WaylandProxy<WlSurfaceClient>,
        width: Int32,
        height: Int32,
        scale: Double,
        presentationContextID: UInt32,
        refreshMillihertz: Int32
    ) -> UInt64? {
        let id = nextOutputID
        nextOutputID &+= 1
        Self.log(
            "window-client-render: add surface output=\(id) extent=\(width)x\(height)")
        guard let presenter = WaylandBackingStorePresenter(
            core: core,
            outputID: id,
            surface: waylandSurface,
            connection: connection)
        else {
            Self.log("window-client-render: output=\(id) presenter creation failed")
            return nil
        }
        Self.log("window-client-render: output=\(id) configuring backing stores")
        guard presenter.configure(
            width: width,
            height: height)
        else {
            Self.log(
                "window-client-render: output=\(id) backing-store configuration failed")
            presenter.teardown()
            return nil
        }
        Self.log(
            "window-client-render: output=\(id) backing stores ready "
                + "extent=\(presenter.lastExtentWidth)x"
                + "\(presenter.lastExtentHeight)")
        presenters[id] = presenter
        refreshMillihertzByOutput[id] = refreshMillihertz
        presentationContextIDByOutput[id] = presentationContextID
        core.attachOutputGeometry(
            outputID: id, logicalX: 0, logicalY: 0,
            logicalWidth: Double(presenter.lastExtentWidth) / scale,
            logicalHeight: Double(presenter.lastExtentHeight) / scale,
            pixelWidth: UInt32(max(0, presenter.lastExtentWidth)),
            pixelHeight: UInt32(max(0, presenter.lastExtentHeight)),
            fractionalScale: scale)
        core.setOutputRoots(
            outputID: id,
            contextID: presentationContextID,
            rootLayerIDs: []
        )
        return id
    }

    /// Route one Wayland backing store to the exact window root published for its
    /// Wayland surface. A missing root intentionally blanks the target until
    /// publication catches up with surface configuration.
    public func setSurfaceRoot(
        _ rootLayerID: UInt64?,
        forSurface id: UInt64,
        label: String
    ) {
        guard presenters[id] != nil,
              let contextID = presentationContextIDByOutput[id]
        else { return }
        let normalizedRootLayerID = rootLayerID ?? 0
        guard presentationRootLayerIDByOutput[id] != normalizedRootLayerID
        else { return }
        presentationRootLayerIDByOutput[id] = normalizedRootLayerID
        Self.log(
            "window-client-render: route output=\(id) context=\(contextID) "
                + "root=\(normalizedRootLayerID) label=\(label)")
        core.setOutputRoots(
            outputID: id,
            contextID: contextID,
            rootLayerIDs: rootLayerID.map { [$0] } ?? [])
    }

    /// Place a surface's target rectangle within the desktop client's shared logical
    /// coordinate space. Content identity is selected independently by
    /// `setSurfaceRoot`; geometry controls projection, never surface routing.
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

    /// Replace a surface's backing-store generation after layer-shell configure.
    public func resizeSurface(_ id: UInt64, width: Int32, height: Int32, scale: Double) {
        guard let presenter = presenters[id] else { return }
        _ = presenter.configure(width: width, height: height)
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
        refreshMillihertzByOutput[id] = nil
        presentationContextIDByOutput[id] = nil
        presentationRootLayerIDByOutput[id] = nil
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
                NucleusWindowClientPresentationTiming.intervalNanoseconds(
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
                    "window-client-render: frame begin presenters=\(presenters.count) "
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
            deviceLost = presenters.values.contains {
                $0.deviceLost
            }
            if startupFrameDiagnosticsRemaining > 0 {
                startupFrameDiagnosticsRemaining -= 1
                Self.log(
                    "window-client-render: frame end posted_outputs="
                        + "\(postedOutputIDs.sorted())")
            }
            return postedOutputIDs
        }
    }

    public func imageResidency(
        for handle: UInt64
    ) -> WindowClientImageResidency {
        switch core.imageResidency(for: handle) {
        case .unknown: .unknown
        case .pending: .pending
        case .resident: .resident
        case .failed: .failed
        }
    }

    private static func log(_ message: String) {
        NucleusLogger(subsystem: "window-client-render").info(message)
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
