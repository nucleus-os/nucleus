import NucleusUI
import NucleusUIEmbedder
// Selective imports: this file needs the layer model's transaction vocabulary,
// but `NucleusLayers` also defines a `Rect`, and the frames here are the UI
// framework's. Naming what is used keeps that unambiguous without qualifying
// every geometry mention.
import class NucleusLayers.Context
import class NucleusLayers.Layer
import struct NucleusLayers.LayerTransaction
import struct NucleusLayers.LayerPropertyUpdate
import typealias NucleusLayers.GeometryRect

// Hosted surfaces: Wayland client surfaces placed inside the compositor's own
// scene.
//
// This is compositor vocabulary, and it lives here rather than in NucleusUI
// because nothing else has the concept — not the shell runtime, not React
// Native. The UI framework vends only the generic seam this needs: a root
// layer to attach under, an insertion index for a window level, and a
// `ScenePlacement` describing where content sorts.

@MainActor
public final class HostedSurface: ~Sendable {
    public let surfaceID: Int
    public let rootView: View
    public let visualRootLayer: Layer
    public var role: WindowRole
    public var level: WindowLevel
    public private(set) var frame: Rect?
    public private(set) var commitsFrameUpdates: Bool = false
    public private(set) var hasCommittedContent: Bool = false
    private var visualRootWasCreated = false

    public init(
        surfaceID: Int,
        context: Context,
        uiContext: UIContext,
        role: WindowRole = .hostedContent,
        level: WindowLevel = .normal,
        frame: Rect? = nil
    ) {
        self.surfaceID = surfaceID
        self.role = role
        self.level = level
        self.rootView = EmbedderApplication.withContexts(
            uiContext: uiContext,
            visualContext: context
        ) {
            View()
        }
        self.visualRootLayer = context.makeLayer()
        if let frame {
            updateFrame(frame)
        }
    }

    public func beginCommittedFrameUpdates() {
        commitsFrameUpdates = true
    }

    public func markCommittedContent() {
        hasCommittedContent = true
    }

    public func detach() throws(UIError) {
        hasCommittedContent = false
        commitsFrameUpdates = false
        guard visualRootWasCreated else { return }
        var transaction = LayerTransaction(context: visualRootLayer.context)
        do {
            try transaction.remove(visualRootLayer)
            try transaction.commit()
            visualRootWasCreated = false
        } catch {
            transaction.abort()
            throw UIError.invalidArgument(detail: String(describing: error))
        }
    }

    public func updateFrame(_ frame: Rect) {
        self.frame = frame
        let update = LayerPropertyUpdate.decomposedFrame(GeometryRect(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height
        ))
        visualRootLayer.applyProperties(
            update, ambient: commitsFrameUpdates)
    }
}

@MainActor
public final class HostedSurfaceRegistry<Identifier: Hashable>: ~Sendable {
    private let context: Context
    private let uiContext: UIContext
    private var records: [Identifier: HostedSurface] = [:]
    private var order: [Identifier] = []
    private var nextSurfaceID: Int

    public init(
        context: Context,
        uiContext: UIContext,
        firstSurfaceID: Int = 1
    ) {
        self.context = context
        self.uiContext = uiContext
        self.nextSurfaceID = firstSurfaceID
    }

    public func surface(
        for identifier: Identifier,
        frame: Rect? = nil,
        role: WindowRole = .hostedContent,
        level: WindowLevel = .normal
    ) -> HostedSurface {
        if let surface = records[identifier] {
            surface.role = role
            surface.level = level
            if let frame {
                surface.updateFrame(frame)
            }
            return surface
        }
        let surface = HostedSurface(
            surfaceID: nextSurfaceID,
            context: context,
            uiContext: uiContext,
            role: role,
            level: level,
            frame: frame
        )
        records[identifier] = surface
        order.append(identifier)
        nextSurfaceID += 1
        return surface
    }

    public func surfaceID(for identifier: Identifier) -> Int? {
        records[identifier]?.surfaceID
    }

    public var surfaces: [HostedSurface] {
        order.compactMap { records[$0] }
    }

    @discardableResult
    public func detachSurface(_ identifier: Identifier) throws(UIError) -> Bool {
        guard let surface = records.removeValue(forKey: identifier) else {
            return false
        }
        order.removeAll { $0 == identifier }
        try surface.detach()
        return true
    }

    public func updateFrame(_ frame: Rect) {
        for surface in records.values {
            surface.updateFrame(frame)
        }
    }

    /// Map the registered surfaces to the generic placements publication
    /// understands. `role` stays here — publication never read it.
    public func placements() -> [ScenePlacement] {
        order.compactMap { identifier -> ScenePlacement? in
            guard let surface = records[identifier] else {
                return nil
            }
            return ScenePlacement(
                id: UInt64(surface.surfaceID),
                rootLayerID: surface.visualRootLayer.id.rawValue,
                level: surface.level,
                visible: surface.hasCommittedContent
            )
        }
    }

    /// Attach one surface's root under the scene, at the index the scene says
    /// content at that level belongs. The scene answers *where*; this owns the
    /// hosted-surface bookkeeping that follows.
    public func attach<Result>(
        _ surface: HostedSurface,
        in scene: WindowScene,
        using attach: (View, Int, Layer, UInt32) throws -> Result
    ) throws -> Result {
        let parentLayer = try scene.attachedRootLayer()
        let index = scene.sublayerIndex(forLevel: surface.level)
        try surface.attachVisualRoot(to: parentLayer, at: index)
        let result = try attach(
            surface.rootView,
            surface.surfaceID,
            surface.visualRootLayer,
            0
        )
        surface.markCommittedContent()
        surface.beginCommittedFrameUpdates()
        return result
    }

    /// Attach every surface passing `shouldAttach`, offsetting within a level so
    /// siblings do not collide.
    @discardableResult
    public func attachAll(
        _ surfaces: [HostedSurface],
        in scene: WindowScene,
        where shouldAttach: (HostedSurface) -> Bool,
        using attach: (View, Int, Layer, UInt32) throws -> Void
    ) throws -> Bool {
        var didAttach = false
        var parentLayer: Layer?
        var attachedAtLevel: [WindowLevel: UInt32] = [:]
        for surface in surfaces where shouldAttach(surface) {
            let resolvedParent = try parentLayer ?? scene.attachedRootLayer()
            parentLayer = resolvedParent
            let baseIndex = scene.sublayerIndex(forLevel: surface.level)
            let levelOffset = attachedAtLevel[surface.level] ?? 0
            try surface.attachVisualRoot(
                to: resolvedParent,
                at: baseIndex + levelOffset
            )
            try attach(
                surface.rootView,
                surface.surfaceID,
                surface.visualRootLayer,
                0
            )
            attachedAtLevel[surface.level] = levelOffset + 1
            surface.markCommittedContent()
            surface.beginCommittedFrameUpdates()
            didAttach = true
        }
        return didAttach
    }
}

private extension HostedSurface {
    func attachVisualRoot(to parent: Layer, at index: UInt32) throws(UIError) {
        var transaction = LayerTransaction(context: visualRootLayer.context)
        do {
            if !visualRootWasCreated {
                try transaction.createExisting(visualRootLayer)
            }
            try transaction.insert(visualRootLayer, into: parent, at: index)
            try transaction.commit()
            visualRootWasCreated = true
        } catch {
            transaction.abort()
            throw UIError.invalidArgument(detail: String(describing: error))
        }
    }
}
