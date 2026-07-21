@_spi(NucleusCompositor) import NucleusLayers
import NucleusRenderHost

/// Failure type for the scene author's rich-throwing entry points. One case: the
/// caller maps any thrown layer/transaction error to this single tag.
public enum HostCallError: Error {
    case failed
}

/// Per-edge chrome reservation around a window's content, mirroring
/// `NSEdgeInsets` (top, left, bottom, right ordering). The scene author insets
/// the content viewport (and the scaled backing) by these within the presented
/// outer frame, leaving the band for compositor-drawn chrome. All zero for
/// undecorated and fullscreen windows.
public struct WindowEdgeInsets: Sendable, Equatable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = WindowEdgeInsets()
}

private struct AuthoredWindowLayout: Equatable {
    let frame: GeometryRect
    let baseSize: GeometrySize
    let backingFrame: GeometryRect?
    let chromeInsets: WindowEdgeInsets
    let chromeFocused: Bool
    let windowOpacity: Double
    let overlayOpacity: Double
}

@MainActor
public final class WindowSceneAuthor {
    public typealias CommitSinkFactory = @MainActor () throws(LayerError) -> any CommitSink

    private static let windowCornerRadius: Float = 10

    private let commitSinkFactory: CommitSinkFactory
    private var contexts: [UInt64: Context] = [:]
    private var contextsByID: [UInt32: Context] = [:]
    private var scenes: [UInt64: WindowScene] = [:]

    // Compositor-root ownership — the scene feeder's self-hosting path, and the live
    // scene authority. The author owns the `.compositor` context, the root container every
    // window hosts beneath, and — per surface — the `RemoteHostLayer` (kind `.host`,
    // pointing at the surface's own context) plus its z-orderable container. The feeder
    // drives this through the self-allocating `surfaceAttached(surfaceID:frame:)` and
    // `setWindowOrder`.
    private var rootContext: Context?
    private var compositorRoot: LayerID = LayerID(rawValue: 0)
    private var hostingBySurface: [UInt64: (host: LayerID, container: LayerID)] = [:]
    private var lastWindowOrder: [UInt64]?
    private var authoredLayouts: [UInt64: AuthoredWindowLayout] = [:]

    // Child surfaces (subsurfaces, popups) share their parent window's context: a
    // single backing layer parented under the parent's content (subsurface) or
    // popup (popup) layer. They register a lightweight `scenes` entry so the content
    // publish (`setContent`/`setBackgroundEffect`) resolves their backing layer, but
    // are tracked here so teardown removes only the child's own layer and never the
    // parent window's root/content/popup tree.
    private var childSurfaces: Set<UInt64> = []

    /// Layer transactions update the local model eagerly even when a commit sink
    /// rejects the encoded transaction. Destructive author operations therefore
    /// snapshot and restore their local topology on failure so a retry emits the
    /// same removal instead of silently accepting an empty mutation.
    private struct LocalLayerTopology {
        let id: LayerID
        let descriptor: LayerDescriptor
        let parentID: LayerID?
        let index: UInt32
    }

    public init(commitSinkFactory: @escaping CommitSinkFactory) {
        self.commitSinkFactory = commitSinkFactory
    }

    private func captureTopology(
        in context: Context,
        layerIDs: Set<LayerID>
    ) -> [LocalLayerTopology] {
        layerIDs.compactMap { id in
            guard let layer = context.layers[id] else { return nil }
            let index = layer.parent?.sublayers.firstIndex {
                $0 === layer
            }.map(UInt32.init) ?? UInt32.max
            return LocalLayerTopology(
                id: id,
                descriptor: layer.descriptor,
                parentID: layer.parent?.id,
                index: index)
        }
    }

    private func restoreTopology(
        _ topology: [LocalLayerTopology],
        in context: Context,
        removing createdIDs: Set<LayerID> = []
    ) {
        var rollback = LayerTransaction(context: context)
        for id in createdIDs {
            if let layer = context.layers[id] {
                try? rollback.remove(layer)
            }
        }
        for item in topology where context.layers[item.id] == nil {
            _ = rollback.createLayer(
                id: item.id,
                item.descriptor)
        }
        let byID = Dictionary(
            uniqueKeysWithValues: topology.map { ($0.id, $0) })
        func depth(_ item: LocalLayerTopology) -> Int {
            var result = 0
            var parent = item.parentID
            var visited: Set<LayerID> = []
            while let id = parent,
                  visited.insert(id).inserted,
                  let next = byID[id]
            {
                result += 1
                parent = next.parentID
            }
            return result
        }
        for item in topology.sorted(by: {
            let left = depth($0)
            let right = depth($1)
            return left == right
                ? $0.index < $1.index
                : left < right
        }) {
            guard let layer = context.layers[item.id] else { continue }
            let parent = item.parentID.flatMap { context.layers[$0] }
            try? rollback.insert(
                layer,
                into: parent,
                at: item.index)
        }
        rollback.abort()
    }

    /// Ensure the compositor-root context (`.compositor`) and its root container exist.
    /// Idempotent. The root context's well-known id makes the render server compose
    /// every hosted window context beneath this container.
    public func ensureCompositorRoot() throws {
        if rootContext != nil { return }
        let context = try Context(id: .compositor, commitSink: commitSinkFactory())
        var rootID = LayerID(rawValue: 0)
        try context.transaction { transaction in
            let root = transaction.createLayer(LayerDescriptor(kind: .container))
            try transaction.insert(root)
            rootID = root.id
        }
        compositorRoot = rootID
        contextsByID[ContextID.compositor.rawValue] = context
        rootContext = context
    }

    /// Host `windowContext` beneath the compositor root: a `RemoteHostLayer`
    /// (kind `.host`, target = the window's context) inside a per-window container
    /// that is z-ordered into the root by `setWindowOrder`.
    private func hostContextInRoot(surfaceID: UInt64, windowContext: Context) throws {
        guard let rootContext else { return }
        let rootLayer = rootContext.importExistingLayer(id: compositorRoot)
        var hostID = LayerID(rawValue: 0)
        var containerID = LayerID(rawValue: 0)
        try rootContext.transaction { transaction in
            let container = transaction.createLayer(LayerDescriptor(kind: .container))
            let host = transaction.createLayer(LayerDescriptor(kind: .host, targetContextID: windowContext.id))
            // Establish the container's ancestry first. Besides matching the
            // back-to-front ownership order, this keeps transaction validation
            // from having to reason about a child whose new parent has not itself
            // been attached yet (the live Noctalia attach exposed that as a false
            // layerCycle rejection).
            try transaction.insert(container, into: rootLayer, at: UInt32.max)
            try transaction.insert(host, into: container, at: 0)
            hostID = host.id
            containerID = container.id
        }
        hostingBySurface[surfaceID] = (host: hostID, container: containerID)
        lastWindowOrder = nil
    }

    /// Re-attach each hosted window's container into the compositor root at its
    /// back-to-front z-index. The per-frame z-order sync, driven by the feeder.
    public func setWindowOrder(_ surfaceIDsBackToFront: [UInt64]) throws {
        guard surfaceIDsBackToFront != lastWindowOrder else { return }
        guard let rootContext else { return }
        let rootLayer = rootContext.importExistingLayer(id: compositorRoot)
        try rootContext.transaction { transaction in
            for (index, surfaceID) in surfaceIDsBackToFront.enumerated() {
                guard let hosting = hostingBySurface[surfaceID] else { continue }
                let container = rootContext.importExistingLayer(id: hosting.container)
                let host = rootContext.importExistingLayer(id: hosting.host)
                // Z-order publication is an authoritative topology snapshot, not
                // merely a move. Reassert both nodes so a prior atomic rejection or
                // transient detach cannot leave a mapped surface permanently absent.
                try transaction.createExisting(container)
                try transaction.createExisting(host)
                try transaction.insert(container, into: rootLayer, at: UInt32(index))
                try transaction.insert(host, into: container, at: 0)
            }
        }
        lastWindowOrder = surfaceIDsBackToFront
    }

    public func scene(for surfaceID: UInt64) -> WindowScene? {
        scenes[surfaceID]
    }

    /// The layer context a mapped window surface authors into (the target of its
    /// compositor-root host). The session-lock composition uses this to name the
    /// contexts the locked scanout path is allowed to compose. nil for an unknown or
    /// child surface.
    public func contextID(forSurface surfaceID: UInt64) -> ContextID? {
        contexts[surfaceID]?.id
    }

    private func context(for id: ContextID) throws(LayerError) -> Context {
        if let context = contextsByID[id.rawValue] {
            return context
        }
        let context = try Context(id: id, commitSink: commitSinkFactory())
        contextsByID[id.rawValue] = context
        return context
    }

    /// Self-allocating attach: create the window's own context and full scene tree
    /// (root → content → backing, plus a popup root), then host that context
    /// beneath the compositor root. The author mints every layer id (the scene
    /// feeder supplies only the surface id + frame). Returns the backing layer id (the
    /// surface's external-content target the feeder records for the content publish).
    @discardableResult
    public func surfaceAttached(surfaceID: UInt64, frame: GeometryRect = .zero) throws -> UInt64 {
        if let scene = scenes[surfaceID] {
            return scene.backingLayer?.rawValue ?? 0
        }
        try ensureCompositorRoot()
        let context = try Context(commitSink: commitSinkFactory())
        var rootID = LayerID(rawValue: 0)
        var contentID = LayerID(rawValue: 0)
        var popupID = LayerID(rawValue: 0)
        var backingID = LayerID(rawValue: 0)
        try context.transaction { transaction in
            let root = transaction.createLayer(.init(role: .windowRoot, frame: frame, shadow: Self.defaultWindowShadow))
            let content = transaction.createLayer(.init(
                role: .windowContentViewport,
                frame: GeometryRect(x: 0, y: 0, width: frame.width, height: frame.height)
            ))
            let popup = transaction.createLayer()
            let backing = transaction.createLayer(.init(
                frame: GeometryRect(x: 0, y: 0, width: frame.width, height: frame.height)
            ))
            try transaction.insert(root)
            try transaction.insert(content, into: root, at: 0)
            try transaction.insert(popup, into: root, at: UInt32.max)
            try transaction.insert(backing, into: content, at: 0)

            var rootStyle = LayerPropertyUpdate.decomposedFrame(frame, actionPolicy: .default)
            rootStyle.shadow = Self.defaultWindowShadow
            rootStyle.cornerRadii = Self.windowCornerRadii
            try transaction.setProperties(rootStyle, for: root)

            var contentStyle = LayerPropertyUpdate.decomposedFrame(
                GeometryRect(x: 0, y: 0, width: frame.width, height: frame.height)
            )
            contentStyle.clip = Self.clip(for: frame, squareTop: false)
            try transaction.setProperties(contentStyle, for: content)

            try transaction.setProperties(
                .decomposedFrame(GeometryRect(x: 0, y: 0, width: frame.width, height: frame.height)),
                for: popup
            )

            rootID = root.id
            contentID = content.id
            popupID = popup.id
            backingID = backing.id
        }
        try hostContextInRoot(surfaceID: surfaceID, windowContext: context)
        contexts[surfaceID] = context
        contextsByID[context.id.rawValue] = context
        scenes[surfaceID] = WindowScene(
            surfaceID: surfaceID,
            rootLayer: rootID,
            contentLayer: contentID,
            popupLayer: popupID,
            backingLayer: backingID,
            frame: frame
        )
        return backingID.rawValue
    }

    public func surfaceDestroyed(surfaceID: UInt64) throws {
        if let hosting = hostingBySurface[surfaceID], let rootContext {
            let topology = captureTopology(
                in: rootContext,
                layerIDs: [hosting.host, hosting.container])
            do {
                try rootContext.transaction { transaction in
                    if let host = rootContext.layers[hosting.host] { try transaction.remove(host) }
                    if let container = rootContext.layers[hosting.container] { try transaction.remove(container) }
                }
            } catch {
                restoreTopology(topology, in: rootContext)
                throw error
            }
            hostingBySurface[surfaceID] = nil
            lastWindowOrder = nil
        }
        guard let context = contexts[surfaceID], let scene = scenes[surfaceID] else {
            return
        }
        let topology = captureTopology(
            in: context,
            layerIDs: Set(context.layers.keys))
        do {
            try context.transaction { transaction in
                if let backingID = scene.backingLayer, let backing = context.layers[backingID] {
                    try transaction.detach(backing)
                }
                if let popup = context.layers[scene.popupLayer] {
                    try transaction.remove(popup)
                }
                if let content = context.layers[scene.contentLayer] {
                    try transaction.remove(content)
                }
                if let root = context.layers[scene.rootLayer] {
                    try transaction.remove(root)
                }
            }
        } catch {
            restoreTopology(topology, in: context)
            throw error
        }
        contexts[surfaceID] = nil
        if !contexts.values.contains(where: { $0 === context }) {
            contextsByID[context.id.rawValue] = nil
        }
        scenes[surfaceID] = nil
        authoredLayouts[surfaceID] = nil
    }

    /// What a child surface parents under in its parent window's scene.
    public enum ChildSurfaceKind: Sendable {
        case subsurface  // under the parent's content viewport, composited with the window
        case popup       // under the parent's popup layer, above the window content
    }

    /// Attach a child surface (subsurface/popup) as a single backing layer in its
    /// parent window's context, parented under the parent's content or popup layer.
    /// Idempotent; returns the backing layer id (the content-publish target). No-ops
    /// to 0 if the parent has no scene yet. Adds a per-child sub-layer under the
    /// window's content/popup root.
    @discardableResult
    public func childSurfaceAttached(
        surfaceID: UInt64,
        parentSurfaceID: UInt64,
        kind: ChildSurfaceKind,
        frame: GeometryRect
    ) throws -> UInt64 {
        if let scene = scenes[surfaceID] { return scene.backingLayer?.rawValue ?? 0 }
        guard let parentContext = contexts[parentSurfaceID], let parentScene = scenes[parentSurfaceID] else {
            return 0
        }
        let hostLayerID = (kind == .popup) ? parentScene.popupLayer : parentScene.contentLayer
        var backingID = LayerID(rawValue: 0)
        try parentContext.transaction { transaction in
            let backing = transaction.createLayer(.init(frame: frame))
            let host = parentContext.importExistingLayer(id: hostLayerID)
            // Above the parent's own content (index 0) / earlier children; the
            // back-to-front child order is the order children attach + re-layout.
            try transaction.insert(backing, into: host, at: UInt32.max)
            try transaction.setProperties(.decomposedFrame(frame), for: backing)
            backingID = backing.id
        }
        childSurfaces.insert(surfaceID)
        contexts[surfaceID] = parentContext
        scenes[surfaceID] = WindowScene(
            surfaceID: surfaceID,
            rootLayer: parentScene.rootLayer,
            contentLayer: hostLayerID,
            popupLayer: parentScene.popupLayer,
            backingLayer: backingID,
            frame: frame
        )
        return backingID.rawValue
    }

    /// Reposition/resize a child surface's backing layer within its parent context.
    public func layoutChildSurface(surfaceID: UInt64, frame: GeometryRect) throws {
        guard childSurfaces.contains(surfaceID),
            let context = contexts[surfaceID], let scene = scenes[surfaceID],
            let backingID = scene.backingLayer
        else { return }
        let backing = context.importExistingLayer(id: backingID)
        try context.transaction { transaction in
            try transaction.setProperties(.decomposedFrame(frame), for: backing)
        }
    }

    /// Tear down a child surface: remove only its own backing layer; the parent
    /// window's scene is untouched (the child shares the parent's context). No-ops
    /// for a non-child surface id, so it is safe to call on every surface teardown.
    public func childSurfaceDetached(surfaceID: UInt64) throws {
        guard childSurfaces.contains(surfaceID),
            let context = contexts[surfaceID], let scene = scenes[surfaceID]
        else { return }
        if let backingID = scene.backingLayer, let backing = context.layers[backingID] {
            let topology = captureTopology(
                in: context,
                layerIDs: [backingID])
            do {
                try context.transaction { transaction in
                    try transaction.remove(backing)
                }
            } catch {
                restoreTopology(topology, in: context)
                throw error
            }
        }
        childSurfaces.remove(surfaceID)
        contexts[surfaceID] = nil
        scenes[surfaceID] = nil
        authoredLayouts[surfaceID] = nil
        // The context belongs to the parent window — never cleared here.
    }

    public func applyLayout(
        surfaceID: UInt64,
        frame: GeometryRect,
        baseSize: GeometrySize,
        backingFrame: GeometryRect?,
        chromeInsets: WindowEdgeInsets = .zero,
        chromeFocused: Bool = false,
        windowOpacity: Double = 1,
        overlayOpacity: Double = 1
    ) throws {
        guard let context = contexts[surfaceID], var scene = scenes[surfaceID] else {
            return
        }
        let layout = AuthoredWindowLayout(
            frame: frame, baseSize: baseSize, backingFrame: backingFrame,
            chromeInsets: chromeInsets, chromeFocused: chromeFocused,
            windowOpacity: windowOpacity,
            overlayOpacity: overlayOpacity)
        guard authoredLayouts[surfaceID] != layout else { return }
        try context.transaction { transaction in
            try applyGeometry(frame: frame, baseSize: baseSize, backingFrame: backingFrame, chromeInsets: chromeInsets, chromeFocused: chromeFocused, windowOpacity: windowOpacity, overlayOpacity: overlayOpacity, scene: &scene, context: context, transaction: &transaction)
        }
        scene.frame = frame
        scenes[surfaceID] = scene
        authoredLayouts[surfaceID] = layout
    }

    /// Begin a tiling content crossfade: create a transient snapshot-overlay layer (a
    /// sibling above the backing under `content`) showing the frozen pre-tile snapshot. Its
    /// geometry AND opacity are authored each frame by `applyGeometry` — identical transform
    /// to the backing, opacity from the spring's remaining displacement — so it overlays the
    /// live backing exactly and dissolves in step with the motion. `endContentCrossfade`
    /// removes it once the opacity has reached zero at settle.
    public func beginContentCrossfade(
        surfaceID: UInt64,
        snapshotHandle: UInt64
    ) throws(HostCallError) {
        guard let context = contexts[surfaceID], var scene = scenes[surfaceID]
        else { throw .failed }
        do {
            let previousTopology = scene.overlaySnapshotLayer.map {
                captureTopology(in: context, layerIDs: [$0])
            } ?? []
            var overlayID: LayerID? = nil
            do {
                try context.transaction { transaction in
                    guard context.layers[scene.contentLayer] != nil else {
                        throw HostCallError.failed
                    }
                    // Replacement is one accepted topology mutation: there is never a
                    // committed state with neither the old nor new overlay because a
                    // superseding transition happened to fail halfway through.
                    if let existing = scene.overlaySnapshotLayer,
                       let layer = context.layers[existing]
                    {
                        try transaction.remove(layer)
                    }
                    let overlay = transaction.createLayer(.init(
                        initialContent: LayerContent(kind: .snapshot, handle: snapshotHandle)
                    ))
                    overlayID = overlay.id
                    try transaction.insert(overlay, into: context.layers[scene.contentLayer]!, at: 1)
                }
            } catch {
                restoreTopology(
                    previousTopology,
                    in: context,
                    removing: Set(overlayID.map { [$0] } ?? []))
                throw error
            }
            scene.overlaySnapshotLayer = overlayID
            scenes[surfaceID] = scene
            authoredLayouts[surfaceID] = nil
        } catch {
            throw .failed
        }
    }

    /// Remove the snapshot-overlay layer and clear the scene's crossfade state.
    public func endContentCrossfade(surfaceID: UInt64) throws(HostCallError) {
        guard let context = contexts[surfaceID], var scene = scenes[surfaceID] else { return }
        do {
            let topology = scene.overlaySnapshotLayer.map {
                captureTopology(in: context, layerIDs: [$0])
            } ?? []
            do {
                if let overlayID = scene.overlaySnapshotLayer, let overlay = context.layers[overlayID] {
                    try context.transaction { transaction in try transaction.remove(overlay) }
                }
            } catch {
                restoreTopology(topology, in: context)
                throw error
            }
            scene.overlaySnapshotLayer = nil
            scenes[surfaceID] = scene
            authoredLayouts[surfaceID] = nil
        } catch {
            throw .failed
        }
    }

    public func setContent(
        surfaceID: UInt64,
        content: LayerContent,
        contentSample: ContentSample? = nil
    ) throws {
        guard let context = contexts[surfaceID], let scene = scenes[surfaceID] else {
            return
        }
        try context.transaction { transaction in
            let targetID = scene.backingLayer ?? scene.contentLayer
            guard let target = context.layers[targetID] else {
                return
            }
            try transaction.setProperties(LayerPropertyUpdate(content: content, contentSample: contentSample), for: target)
        }
    }

    public func setBackgroundEffect(
        surfaceID: UInt64,
        enabled: Bool,
        regions: BackgroundEffectRegions = BackgroundEffectRegions()
    ) throws {
        guard let context = contexts[surfaceID], let scene = scenes[surfaceID] else {
            return
        }
        try context.transaction { transaction in
            let targetID = scene.backingLayer ?? scene.contentLayer
            guard let target = context.layers[targetID] else {
                return
            }
            try transaction.setProperties(
                LayerPropertyUpdate(backgroundEffect: enabled, backgroundEffectRegions: regions),
                for: target)
        }
    }

    /// Repaint the traffic-light cluster for a hover/press change, independent of layout.
    /// `hovered`/`pressed` are 1-based button codes (0 = none, 1 = close, 2 = minimize,
    /// 3 = maximize). The cluster is repainted only when the pair actually changes.
    public func setChromeButtonState(surfaceID: UInt64, hovered: UInt32, pressed: UInt32) throws(HostCallError) {
        guard let context = contexts[surfaceID], var scene = scenes[surfaceID] else { return }
        guard scene.titlebarButtonsHovered != hovered || scene.titlebarButtonsPressed != pressed else { return }
        defer { scenes[surfaceID] = scene }
        scene.titlebarButtonsHovered = hovered
        scene.titlebarButtonsPressed = pressed
        guard let buttonID = scene.titlebarButtonLayer, let buttonLayer = context.layers[buttonID] else {
            return
        }
        let focused = scene.titlebarButtonsFocused ?? false
        do {
            try context.transaction { transaction in
                try transaction.setPaintCommands(
                    Self.trafficLightCommands(
                        focused: focused,
                        hovered: hovered,
                        pressed: pressed,
                        titlebarHeight: Float(scene.titlebarHeight)
                    ),
                    width: Float(Self.trafficLightClusterWidth),
                    height: Float(scene.titlebarHeight),
                    for: buttonLayer
                )
            }
        } catch {
            throw .failed
        }
    }

    public func setOpacity(surfaceID: UInt64, opacity: Double) throws {
        guard let context = contexts[surfaceID], let scene = scenes[surfaceID], let root = context.layers[scene.rootLayer] else {
            return
        }
        try context.transaction { transaction in
            try transaction.setProperties(LayerPropertyUpdate(opacity: opacity), for: root)
        }
    }

    public func animateOpacity(
        surfaceID: UInt64,
        from: Double,
        to: Double,
        duration: Double,
        completionToken: UInt64
    ) throws(HostCallError) {
        guard let context = contexts[surfaceID], let scene = scenes[surfaceID], let root = context.layers[scene.rootLayer] else {
            return
        }
        do {
            var transaction = LayerTransaction(context: context, completionToken: completionToken)
            try transaction.setProperties(LayerPropertyUpdate(opacity: to), for: root)
            try transaction.add(
                .scalar(keyPath: .opacity, from: from, to: to, duration: duration, curve: .bezier(.easeOut)),
                to: root
            )
            try transaction.commit()
        } catch {
            throw .failed
        }
    }

    /// Hairline window outline drawn on the root of a decorated window.
    private static let windowBorderColor = Color(0, 0, 0, 0.35)
    /// Hairline window-outline stroke. Drawn over the edge (the content runs
    /// edge-to-edge), so it is a fixed width independent of the content insets.
    private static let windowBorderWidth: Float = 1

    private static var windowCornerRadii: CornerRadii {
        CornerRadii(uniform: windowCornerRadius)
    }

    private static var defaultWindowShadow: Shadow {
        Shadow(
            offsetX: 0,
            offsetY: 18,
            blurRadius: 40,
            cornerRadius: Double(windowCornerRadius),
            opacity: 0.30,
            color: Color(0, 0, 0, 1)
        )
    }

    /// The content clip. For a decorated window the top corners are square so the
    /// content meets the titlebar flush (the titlebar rounds the window's top); the
    /// bottom corners round to form the window's bottom. A borderless window rounds
    /// all four (it has no titlebar to provide the top).
    private static func clip(for frame: GeometryRect, squareTop: Bool) -> ClipOp {
        ClipOp(
            rectX: 0,
            rectY: 0,
            rectW: Float(frame.width),
            rectH: Float(frame.height),
            radiusTL: squareTop ? 0 : windowCornerRadius,
            radiusTR: squareTop ? 0 : windowCornerRadius,
            radiusBR: windowCornerRadius,
            radiusBL: windowCornerRadius,
            antiAlias: true
        )
    }

    private func applyGeometry(
        frame: GeometryRect,
        baseSize: GeometrySize,
        backingFrame: GeometryRect?,
        chromeInsets: WindowEdgeInsets,
        chromeFocused: Bool,
        windowOpacity: Double,
        overlayOpacity: Double,
        scene: inout WindowScene,
        context: Context,
        transaction: inout LayerTransaction
    ) throws {
        // Crisp-chrome scale-on-animate: the compositor publishes the *presented* frame
        // (`frame`, the eased animated OUTER rect) plus the model *base* size (`baseSize`,
        // the size the client's committed content buffer represents) and the chrome insets
        // reserved around the content. The root (shadow, corner radii) is authored at the
        // real presented outer size so it stays sharp throughout the animation. Live
        // client pixels remain at their committed logical size; only an explicit
        // transition snapshot is allowed to scale toward a requested layout. With zero
        // insets the content viewport is the full frame.
        let contentViewport = GeometryRect(
            x: chromeInsets.left,
            y: chromeInsets.top,
            width: max(1.0, frame.width - chromeInsets.left - chromeInsets.right),
            height: max(1.0, frame.height - chromeInsets.top - chromeInsets.bottom)
        )
        let baseW = max(1.0, baseSize.width)
        let baseH = max(1.0, baseSize.height)
        let sx = contentViewport.width / baseW
        let sy = contentViewport.height / baseH

        // Whether this window carries server-drawn chrome (a titlebar reservation).
        let hasChrome = chromeInsets.top > 0

        // Root: the real animated outer frame, no scale → crisp shadow + corner radii at
        // the true size. transform set to identity explicitly to overwrite any prior scale.
        // A decorated window also gets a hairline border — the visible window outline.
        if let root = context.layers[scene.rootLayer] {
            var update = LayerPropertyUpdate.decomposedFrame(frame, actionPolicy: .none)
            update.transform = GeometryTransform.identity
            update.shadow = Self.defaultWindowShadow
            update.cornerRadii = Self.windowCornerRadii
            let border: BorderEdge = hasChrome
                ? BorderEdge(width: Self.windowBorderWidth, color: Self.windowBorderColor)
                : .none
            update.borderTop = border
            update.borderRight = border
            update.borderBottom = border
            update.borderLeft = border
            update.opacity = windowOpacity
            try transaction.setProperties(update, for: root)
        }
        // Content: the inset content viewport within the frame, no scale, rounded-corner
        // clip at the viewport size → crisp corners that clip the live backing below.
        let contentLocalFrame = GeometryRect(x: 0, y: 0, width: contentViewport.width, height: contentViewport.height)
        if let content = context.layers[scene.contentLayer] {
            var update = LayerPropertyUpdate.decomposedFrame(contentViewport, actionPolicy: .none)
            update.transform = GeometryTransform.identity
            // A chromed window rounds only its bottom corners (the titlebar
            // provides the rounded top); the seam where content meets the
            // titlebar stays square and flush. A borderless window rounds all
            // four corners since it has no titlebar above it.
            update.clip = Self.clip(for: contentLocalFrame, squareTop: hasChrome)
            try transaction.setProperties(update, for: content)
        }
        // Popup: sibling of content under root, anchored at the content origin (popups are
        // positioned in content-local coordinates) and unclipped so they may overflow the
        // window's rounded corners.
        if let popup = context.layers[scene.popupLayer] {
            try transaction.setProperties(
                .decomposedFrame(
                    GeometryRect(
                        x: contentViewport.x,
                        y: contentViewport.y,
                        width: contentViewport.width,
                        height: contentViewport.height
                    ),
                    actionPolicy: .none
                ),
                for: popup
            )
        }
        // The live client backing always keeps its committed logical geometry.
        // Only the explicit transition snapshot may scale toward a requested frame;
        // stale live pixels are never stretched to impersonate an uncommitted size.
        if let backingFrame {
            let backingUpdate = LayerPropertyUpdate(
                actionPolicy: .none,
                position: GeometryPoint(x: backingFrame.x, y: backingFrame.y),
                bounds: GeometrySize(width: backingFrame.width, height: backingFrame.height),
                anchorPoint: GeometryPoint(x: 0, y: 0),
                transform: GeometryTransform.identity
            )
            if let backingID = scene.backingLayer, let backing = context.layers[backingID] {
                try transaction.setProperties(backingUpdate, for: backing)
            }
            if let overlayID = scene.overlaySnapshotLayer, let overlay = context.layers[overlayID] {
                var overlayUpdate = LayerPropertyUpdate(
                    actionPolicy: .none,
                    position: GeometryPoint(x: backingFrame.x * sx, y: backingFrame.y * sy),
                    bounds: GeometrySize(width: backingFrame.width, height: backingFrame.height),
                    anchorPoint: GeometryPoint(x: 0, y: 0),
                    transform: GeometryTransform.scale(x: sx, y: sy))
                overlayUpdate.opacity = overlayOpacity
                try transaction.setProperties(overlayUpdate, for: overlay)
            }
        }

        // Titlebar — the server-drawn `NSThemeFrame` titlebar band across the top inset,
        // a `.titlebar` backdrop material (the NSVisualEffectView analog) whose
        // `isEmphasized` tracks key-window focus. Created lazily for a decorated window,
        // laid out each frame to the eased frame width, and torn down when the window goes
        // borderless. The bottom corners are square so it meets the content cleanly; the
        // top corners match the window radius.
        if hasChrome {
            let titlebarFrame = GeometryRect(x: 0, y: 0, width: frame.width, height: chromeInsets.top)
            let titlebar: Layer
            if let existing = scene.titlebarLayer, let layer = context.layers[existing] {
                titlebar = layer
            } else {
                let created = transaction.createLayer(.init(frame: titlebarFrame))
                if let root = context.layers[scene.rootLayer] {
                    // Content must composite before chrome. In particular, a
                    // client background-effect pass must never sample or redraw
                    // the titlebar/traffic lights. Popup remains the final child.
                    try transaction.insert(created, into: root, at: 1)
                }
                scene.titlebarLayer = created.id
                titlebar = created
            }
            var update = LayerPropertyUpdate.decomposedFrame(titlebarFrame, actionPolicy: .none)
            update.transform = GeometryTransform.identity
            update.cornerRadii = CornerRadii(
                tl: Self.windowCornerRadius,
                tr: Self.windowCornerRadius,
                br: 0,
                bl: 0
            )
            // Per-corner backdrop rounding: the titlebar rounds only its top
            // corners (matching the window's top) and stays square along the
            // bottom so it meets the content flush at the seam. The explicit
            // shape rect must be non-zero — a zero shape rect would collapse the
            // rounded-clip mask to nothing.
            update.backdropMaterial = BackdropMaterial(
                material: .titlebar,
                emphasized: chromeFocused,
                shapeKind: .rrect,
                opacity: 1,
                shapeRect: SIMD4<Float>(0, 0, Float(frame.width), Float(chromeInsets.top)),
                shapeRadius: SIMD4<Float>(Self.windowCornerRadius, Self.windowCornerRadius, 0, 0)
            )
            try transaction.setProperties(update, for: titlebar)

            // Traffic-light controls: a fixed-size paint layer in the titlebar holding the
            // close/minimize/maximize circles. Position is leading-fixed (independent of
            // window width), so it is laid out once and only repainted when key-window focus
            // flips — never per resize frame. Circle positions mirror
            // `NucleusCompositorServer.WindowFrameView.ButtonLayout`, the canonical button geometry.
            let clusterFrame = GeometryRect(x: 0, y: 0, width: Self.trafficLightClusterWidth, height: chromeInsets.top)
            let buttonLayer: Layer
            if let existing = scene.titlebarButtonLayer, let layer = context.layers[existing] {
                buttonLayer = layer
            } else {
                let created = transaction.createLayer(.init(frame: clusterFrame))
                try transaction.insert(created, into: titlebar, at: 0)
                scene.titlebarButtonLayer = created.id
                scene.titlebarButtonsFocused = nil
                buttonLayer = created
            }
            try transaction.setProperties(.decomposedFrame(clusterFrame, actionPolicy: .none), for: buttonLayer)
            scene.titlebarHeight = chromeInsets.top
            // Hover/press are driven independently by `setChromeButtonState`; a layout pass
            // only needs to repaint when key-window focus flips, carrying the current
            // hover/press state forward.
            if scene.titlebarButtonsFocused != chromeFocused {
                try transaction.setPaintCommands(
                    Self.trafficLightCommands(
                        focused: chromeFocused,
                        hovered: scene.titlebarButtonsHovered,
                        pressed: scene.titlebarButtonsPressed,
                        titlebarHeight: Float(chromeInsets.top)
                    ),
                    width: Float(Self.trafficLightClusterWidth),
                    height: Float(chromeInsets.top),
                    for: buttonLayer
                )
                scene.titlebarButtonsFocused = chromeFocused
            }
        } else if let existing = scene.titlebarLayer {
            if let buttonID = scene.titlebarButtonLayer, let layer = context.layers[buttonID] {
                try transaction.remove(layer)
            }
            scene.titlebarButtonLayer = nil
            scene.titlebarButtonsFocused = nil
            scene.titlebarButtonsHovered = 0
            scene.titlebarButtonsPressed = 0
            scene.titlebarHeight = 0
            if let layer = context.layers[existing] {
                try transaction.remove(layer)
            }
            scene.titlebarLayer = nil
        }
    }

    // Traffic-light geometry — mirrors `NucleusCompositorServer.WindowFrameView.ButtonLayout`, which is
    // the canonical owner of button hit geometry; keep these in sync.
    private static let trafficLightDiameter: Double = 12
    private static let trafficLightSpacing: Double = 20
    private static let trafficLightLeadingInset: Double = 20
    private static let trafficLightClusterWidth: Double = 72

    // Live traffic-light hues (close / minimize / maximize), and the inactive grey a
    // non-key window's buttons settle to. Hovering the cluster lights every button to its
    // live hue (the macOS "show controls on hover" affordance); the pressed button darkens.
    private static let trafficLightColors: [Color] = [
        Color(1.0, 0.373, 0.341, 1), Color(0.996, 0.737, 0.180, 1), Color(0.157, 0.784, 0.251, 1),
    ]
    private static let trafficLightInactive = Color(0.333, 0.333, 0.333, 1)

    private static func trafficLightCommands(
        focused: Bool,
        hovered: UInt32,
        pressed: UInt32,
        titlebarHeight: Float
    ) -> [PaintCommand] {
        let d = Float(trafficLightDiameter)
        let y = (titlebarHeight - d) / 2
        // Any hover over the cluster lights all three buttons (matches AppKit, which reveals
        // the controls together when the pointer enters the group).
        let anyHover = hovered != 0
        var commands: [PaintCommand] = []
        for index in 0..<trafficLightColors.count {
            let code = UInt32(index + 1)
            var color = (focused || anyHover) ? trafficLightColors[index] : trafficLightInactive
            if code == pressed {
                color = Color(color.r * 0.7, color.g * 0.7, color.b * 0.7, color.a)
            }
            let centerX = Float(trafficLightLeadingInset + Double(index) * trafficLightSpacing)
            commands.append(PaintCommand(
                kind: .roundedRect,
                x: centerX - d / 2,
                y: y,
                w: d,
                h: d,
                radius: d / 2,
                color: color
            ))
        }
        return commands
    }
}
