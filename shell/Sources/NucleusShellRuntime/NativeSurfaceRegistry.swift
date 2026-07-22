import NucleusShellInput
import NucleusShellRender
import NucleusUI
import NucleusUIEmbedder

/// The single host for every native shell view presented on a Wayland surface.
/// Role objects own protocol handshakes; this registry owns the shared
/// NucleusUI/window/input/render lifecycle behind those roles.
@MainActor
final class NativeSurfaceRegistry {
    struct Record {
        let surfaceID: UInt
        let waylandSurface: OpaquePointer
        let window: Window
        var renderOutputID: UInt64?
        var refreshMillihertz: Int32
    }

    private let engine: ShellRenderEngine
    private let scene: WindowScene
    private let publicationContext: WindowScenePublicationContext
    private weak var inputRouter: ShellInputRouter?
    private let didChange: () -> Void
    private var records: [UInt: Record] = [:]
    private var publishedRootLayerIDByWindowID: [UInt64: UInt64] = [:]

    init(
        engine: ShellRenderEngine,
        scene: WindowScene,
        publicationContext: WindowScenePublicationContext,
        inputRouter: ShellInputRouter?,
        didChange: @escaping () -> Void
    ) {
        self.engine = engine
        self.scene = scene
        self.publicationContext = publicationContext
        self.inputRouter = inputRouter
        self.didChange = didChange
    }

    @discardableResult
    func register(
        window: Window,
        waylandSurface: OpaquePointer,
        refreshMillihertz: Int32 = 0
    ) -> UInt {
        let surfaceID = UInt(bitPattern: waylandSurface)
        precondition(surfaceID != 0, "a hosted Wayland surface must be non-null")
        precondition(records[surfaceID] == nil, "a Wayland surface may be hosted only once")
        scene.addWindow(window)
        window.orderFront()
        inputRouter?.register(window: window, forSurface: surfaceID)
        records[surfaceID] = Record(
            surfaceID: surfaceID,
            waylandSurface: waylandSurface,
            window: window,
            renderOutputID: nil,
            refreshMillihertz: max(0, refreshMillihertz))
        didChange()
        return surfaceID
    }

    @discardableResult
    func configure(
        surfaceID: UInt,
        logicalOrigin: Point,
        logicalWidth: Double,
        logicalHeight: Double,
        scale: Double,
        refreshMillihertz: Int32
    ) -> Bool {
        guard logicalWidth.isFinite, logicalHeight.isFinite,
              logicalWidth > 0, logicalHeight > 0,
              scale.isFinite, scale > 0,
              var record = records[surfaceID]
        else { return false }

        let frame = Rect(
            origin: logicalOrigin,
            size: Size(width: logicalWidth, height: logicalHeight))
        record.window.setFrame(frame)
        record.window.setSurfaceAssociation(WindowSurfaceAssociation(
            surfaceID: PresentationSurfaceID(rawValue: UInt64(surfaceID)),
            transform: WindowSurfaceTransform(
                windowOriginInSurface: .zero,
                surfaceOriginInOutput: logicalOrigin,
                backingScaleFactor: BackingScaleFactor(scale))))

        let pixelWidth = Self.pixelExtent(logicalWidth, scale: scale)
        let pixelHeight = Self.pixelExtent(logicalHeight, scale: scale)
        let refresh = max(0, refreshMillihertz)
        if let renderOutputID = record.renderOutputID {
            engine.resizeSurface(
                renderOutputID,
                width: pixelWidth,
                height: pixelHeight,
                scale: scale)
            engine.setRefreshMillihertz(refresh, forSurface: renderOutputID)
        } else {
            guard let renderOutputID = engine.addSurface(
                waylandSurface: record.waylandSurface,
                width: pixelWidth,
                height: pixelHeight,
                scale: scale,
                presentationContextID:
                    publicationContext.visualContext.id.rawValue,
                refreshMillihertz: refresh)
            else { return false }
            record.renderOutputID = renderOutputID
        }
        if let renderOutputID = record.renderOutputID {
            engine.placeSurface(
                renderOutputID,
                logicalX: logicalOrigin.x,
                logicalY: logicalOrigin.y,
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight,
                scale: scale)
            engine.setSurfaceRoot(
                publishedRootLayerIDByWindowID[record.window.id.rawValue],
                forSurface: renderOutputID,
                label: record.window.title)
        }
        record.refreshMillihertz = refresh
        records[surfaceID] = record
        didChange()
        return true
    }

    func updateRefreshRate(
        _ refreshMillihertz: Int32,
        surfaceID: UInt
    ) {
        guard var record = records[surfaceID] else { return }
        let refresh = max(0, refreshMillihertz)
        record.refreshMillihertz = refresh
        records[surfaceID] = record
        if let renderOutputID = record.renderOutputID {
            engine.setRefreshMillihertz(refresh, forSurface: renderOutputID)
        }
    }

    func unregister(surfaceID: UInt) {
        guard let record = records.removeValue(forKey: surfaceID) else {
            return
        }
        if let renderOutputID = record.renderOutputID {
            engine.removeSurface(renderOutputID)
        }
        inputRouter?.unregister(surfaceID: surfaceID)
        record.window.setSurfaceAssociation(nil)
        _ = scene.removeWindow(record.window)
        didChange()
    }

    func unregisterAll() {
        for surfaceID in Array(records.keys) {
            unregister(surfaceID: surfaceID)
        }
    }

    func contains(surfaceID: UInt) -> Bool {
        records[surfaceID] != nil
    }

    func renderOutputID(for surfaceID: UInt) -> UInt64? {
        records[surfaceID]?.renderOutputID
    }

    /// Apply the scene publisher's authoritative window-to-root mapping to
    /// every presentable native surface. Surface routing is identity-based;
    /// overlapping global geometry never decides which window a swapchain sees.
    func updatePublishedScene(_ published: PublishedScene) {
        publishedRootLayerIDByWindowID = published.visualContent.reduce(
            into: [:]
        ) { roots, content in
            guard content.visible, content.id != 0, content.rootLayerID != 0
            else { return }
            roots[content.id] = content.rootLayerID
        }
        for record in records.values {
            guard let renderOutputID = record.renderOutputID else { continue }
            engine.setSurfaceRoot(
                publishedRootLayerIDByWindowID[record.window.id.rawValue],
                forSurface: renderOutputID,
                label: record.window.title)
        }
    }

    private static func pixelExtent(
        _ logicalExtent: Double,
        scale: Double
    ) -> Int32 {
        let value = min(
            Double(Int32.max),
            max(1, (logicalExtent * scale).rounded()))
        return Int32(value)
    }
}
