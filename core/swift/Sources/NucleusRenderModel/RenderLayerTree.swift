// Retained-layer nodes and the authoritative structural tree store.

// MARK: - Node identity + role

/// Backing-store layer identity. Mirrors `RenderLayer.LayerId`.
public enum LayerId: Equatable, Sendable {
    case rasterPhase(groupId: UInt64, phaseIndex: UInt32)
}

/// Semantic role used by the consumer-side default-action lookup. Mirrors
/// `animation.LayerRole`.
public enum LayerRole: UInt8, Sendable {
    case generic
    case windowRoot
    case windowContentViewport
    case notification
    case hotkeyOverlay
    case wallpaper
    case dock
}

// MARK: - Damage

/// Per-node invalidation flags. Mirrors `InvalidationFlags` (the packed-struct
/// bools; `_padding` is layout-only and not modeled).
public struct InvalidationFlags: Equatable, Sendable {
    public var structure: Bool = false
    public var content: Bool = false
    public var property: Bool = false
    public var backingReallocate: Bool = false
    public var effectDependency: Bool = false

    public init(
        structure: Bool = false,
        content: Bool = false,
        property: Bool = false,
        backingReallocate: Bool = false,
        effectDependency: Bool = false
    ) {
        self.structure = structure
        self.content = content
        self.property = property
        self.backingReallocate = backingReallocate
        self.effectDependency = effectDependency
    }

    public static let none = InvalidationFlags()

    /// True when any flag is set. Mirrors `InvalidationFlags.any`.
    public func any() -> Bool {
        structure || content || property || backingReallocate || effectDependency
    }
}

/// Per-node damage state. Mirrors `DamageState`.
public struct DamageState: Equatable, Sendable {
    public var flags = InvalidationFlags()
    /// Union of layer-local logical paint damage since the last presented
    /// frame. `nil` while `flags.content` is true means full-bounds damage.
    public var localContentRect: Rect?

    public init(
        flags: InvalidationFlags = InvalidationFlags(),
        localContentRect: Rect? = nil
    ) {
        self.flags = flags
        self.localContentRect = localContentRect
    }

    public mutating func markContent(_ rect: Rect?) {
        if flags.content {
            guard let current = localContentRect, let rect else {
                localContentRect = nil
                return
            }
            let left = min(current.x, rect.x)
            let top = min(current.y, rect.y)
            let right = max(current.x + current.w, rect.x + rect.w)
            let bottom = max(current.y + current.h, rect.y + rect.h)
            localContentRect = Rect(
                x: left,
                y: top,
                w: max(0, right - left),
                h: max(0, bottom - top))
        } else {
            flags.content = true
            localContentRect = rect
        }
    }
}

// MARK: - Layer node

/// A retained render-layer node. Mirrors `RenderLayer.Layer` (minus the deferred
/// `backing`/`animations` fields — see file header).
public struct Layer: Sendable {
    public var id: UInt64
    public var parent: UInt64?
    /// Non-nil exactly when this layer is attached as a context root.
    public var rootContext: ContextID?
    public var children: [UInt64] = []
    public var kind: LayerKind
    public var role: LayerRole = .generic
    public var backdropAttachment: BackdropAttachment?
    public var foregroundVibrancy: ForegroundVibrancyMode = .inherit
    public var model = ModelState()
    public var presentation = PresentationState()
    public var damage = DamageState()
    /// In-flight animations driving this node's presentation overrides. Folded
    /// in by the producer feed and advanced each frame by `RetainedTreeStore.tick`
    /// (10c.4). Mirrors `RenderLayer.Layer.animations`.
    public var animations: [AnimationRecord] = []

    public init(id: UInt64, kind: LayerKind) {
        self.id = id
        self.kind = kind
    }

    // Effective accessors: presentation override beats the model. Delegates to
    // the shared `EffectiveLayer` precedence helpers (8.3).

    public func effectiveTransform() -> M44 {
        EffectiveLayer.transform(model: model.properties, presentation: presentation)
    }

    public func effectiveBounds() -> Bounds {
        EffectiveLayer.bounds(model: model.properties, presentation: presentation)
    }

    public func effectivePosition() -> Point2D {
        EffectiveLayer.position(model: model.properties, presentation: presentation)
    }

    public func effectiveAnchorPoint() -> Point2D {
        EffectiveLayer.anchorPoint(model: model.properties, presentation: presentation)
    }

    public func effectiveScrollOffset() -> Point2D {
        presentation.override_?.scrollOffset ?? model.properties.scrollOffset
    }

    public func effectiveOpacity() -> Float {
        EffectiveLayer.opacity(model: model.properties, presentation: presentation)
    }

    public func effectiveCornerRadii() -> Float4 {
        EffectiveLayer.cornerRadii(model: model, presentation: presentation)
    }

    /// Renderer-authoritative content for this layer. Mirrors `presentedContent`.
    public func presentedContent() -> LayerContent {
        presentation.content
    }

    /// Whether this layer draws anything that contributes its own extent (vs
    /// being a pure structural container). Mirrors `layerContributesOwnExtent`.
    public func contributesOwnExtent() -> Bool {
        if model.visualStyle != nil { return true }
        if case .backdrop = kind { return true }
        switch presentedContent() {
        case .none: return false
        default: return true
        }
    }
}

// MARK: - Tree store

/// Errors from structural tree mutations.
public enum LayerTreeError: Error, Equatable, Sendable {
    case missingLayer
    case missingParentLayer
    case layerCycle
}

/// The retained layer tree: an id→node map plus the ordered root child list.
/// Mirrors `RenderLayer.LayerTree`.
public struct LayerTree: Sendable {
    public var layers: [UInt64: Layer] = [:]
    /// Ordered root layers per producer context. Remote-host expansion resolves
    /// the target context here, while the compositor frame starts from
    /// `compositorContextId`.
    public var contextRoots: [ContextID: [UInt64]] = [:]

    public init(
        layers: [UInt64: Layer] = [:],
        contextRoots: [ContextID: [UInt64]] = [:]
    ) {
        self.layers = layers
        self.contextRoots = contextRoots
        for (context, roots) in contextRoots {
            for id in roots {
                self.layers[id]?.rootContext = context
            }
        }
    }

    /// Read a node by id. Mirrors `get`.
    public func get(_ id: UInt64) -> Layer? {
        layers[id]
    }

    /// Insert (or replace) a node keyed by its id. Mirrors `insertLayer`.
    public mutating func insertLayer(_ node: Layer) {
        layers[node.id] = node
    }

    /// Detach `id` from its parent (or the root list) and clear its parent
    /// pointer. No-op if absent. Mirrors `detach`.
    public mutating func detach(_ id: UInt64) {
        let parentId = layers[id]?.parent
        if let pid = parentId {
            layers[pid]?.children.removeAll { $0 == id }
        }
        if let context = layers[id]?.rootContext {
            contextRoots[context]?.removeAll { $0 == id }
            if contextRoots[context]?.isEmpty == true {
                contextRoots[context] = nil
            }
        }
        layers[id]?.parent = nil
        layers[id]?.rootContext = nil
    }

    /// Detach `id` and remove it from the map. No-op if absent. Mirrors
    /// `removeLayer`.
    public mutating func removeLayer(_ id: UInt64) {
        guard layers[id] != nil else { return }
        var pending = [id]
        var subtree: [UInt64] = []
        var visited: Set<UInt64> = []
        while let current = pending.popLast() {
            guard visited.insert(current).inserted, let layer = layers[current] else { continue }
            subtree.append(current)
            pending.append(contentsOf: layer.children)
        }
        // Detach the subtree root from external structure. Descendants are all
        // removed together, so walking each parent array would only add quadratic work.
        detach(id)
        for nodeID in subtree {
            layers[nodeID] = nil
        }
    }

    /// Attach `id` as a root child at `index` (clamped). The node must exist.
    /// Mirrors `attachRoot`.
    public mutating func attachRoot(_ id: UInt64, index: Int, contextId: ContextID) throws {
        guard layers[id] != nil else { throw LayerTreeError.missingLayer }
        detach(id)
        var roots = contextRoots[contextId] ?? []
        let idx = min(index, roots.count)
        roots.insert(id, at: idx)
        contextRoots[contextId] = roots
        layers[id]?.rootContext = contextId
    }

    /// Ordered roots for a context.
    public func roots(for contextId: ContextID) -> [UInt64] {
        contextRoots[contextId] ?? []
    }

    /// Attach `childId` under `parentId` at `index` (clamped), refusing to
    /// create a cycle. Both nodes must exist. Mirrors `attachChild`.
    public mutating func attachChild(parentId: UInt64, childId: UInt64, index: Int) throws {
        if wouldCreateCycle(childId: childId, parentId: parentId) {
            throw LayerTreeError.layerCycle
        }
        guard layers[parentId] != nil else { throw LayerTreeError.missingParentLayer }
        guard layers[childId] != nil else { throw LayerTreeError.missingLayer }
        detach(childId)
        layers[childId]?.parent = parentId
        layers[childId]?.rootContext = nil
        let count = layers[parentId]?.children.count ?? 0
        let idx = min(index, count)
        layers[parentId]?.children.insert(childId, at: idx)
    }

    /// True when attaching `childId` under `parentId` would form a cycle (i.e.
    /// `childId` is `parentId` or an ancestor of it). Mirrors `wouldCreateCycle`.
    public func wouldCreateCycle(childId: UInt64, parentId: UInt64) -> Bool {
        if childId == parentId { return true }
        var cursor: UInt64? = parentId
        while let id = cursor {
            if id == childId { return true }
            cursor = layers[id]?.parent
        }
        return false
    }
}
