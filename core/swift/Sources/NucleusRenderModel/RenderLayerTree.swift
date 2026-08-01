// Retained-layer nodes and the authoritative structural tree store.

package import NucleusTypes

// MARK: - Node identity + role

/// Backing-store layer identity. Mirrors `RenderLayer.LayerId`.
package enum LayerId: Equatable, Sendable {
    case rasterPhase(groupId: UInt64, phaseIndex: UInt32)
}

package typealias LayerRole = NucleusTypes.LayerRole

// MARK: - Damage

/// Per-node invalidation flags. Mirrors `InvalidationFlags` (the packed-struct
/// bools; `_padding` is layout-only and not modeled).
package struct InvalidationFlags: Equatable, Sendable {
    package var structure: Bool = false
    package var content: Bool = false
    package var property: Bool = false
    package var backingReallocate: Bool = false
    package var effectDependency: Bool = false

    package init(
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

    package static let none = InvalidationFlags()

    /// True when any flag is set. Mirrors `InvalidationFlags.any`.
    package func any() -> Bool {
        structure || content || property || backingReallocate || effectDependency
    }
}

/// Per-node damage state. Mirrors `DamageState`.
package struct DamageState: Equatable, Sendable {
    package var flags = InvalidationFlags()
    /// Union of layer-local logical paint damage since the last presented
    /// frame. `nil` while `flags.content` is true means full-bounds damage.
    package var localContentRect: RenderRect?

    package init(
        flags: InvalidationFlags = InvalidationFlags(),
        localContentRect: RenderRect? = nil
    ) {
        self.flags = flags
        self.localContentRect = localContentRect
    }

    package mutating func markContent(_ rect: RenderRect?) {
        if flags.content {
            guard let current = localContentRect, let rect else {
                localContentRect = nil
                return
            }
            let left = min(current.x, rect.x)
            let top = min(current.y, rect.y)
            let right = max(current.x + current.w, rect.x + rect.w)
            let bottom = max(current.y + current.h, rect.y + rect.h)
            localContentRect = RenderRect(
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
package struct Layer: Sendable {
    package var id: UInt64
    package var parent: UInt64?
    /// Non-nil exactly when this layer is attached as a context root.
    package var rootContext: ContextID?
    package var children: [UInt64] = []
    package var kind: LayerKind
    package var role: LayerRole = .generic
    package var backdropAttachment: BackdropAttachment?
    package var foregroundVibrancy: ForegroundVibrancyMode = .inherit
    package var model = ModelState()
    package var presentation = PresentationState()
    package var damage = DamageState()
    /// In-flight animations driving this node's presentation overrides. Folded
    /// in by the producer feed and advanced each frame by `RetainedTreeStore.tick`
    package var animations: [AnimationRecord] = []

    package init(id: UInt64, kind: LayerKind) {
        self.id = id
        self.kind = kind
    }

    // Effective accessors: presentation override beats the model. Delegates to
    // the shared `EffectiveLayer` precedence helpers (8.3).

    package func effectiveTransform() -> M44 {
        EffectiveLayer.transform(model: model.properties, presentation: presentation)
    }

    package func effectiveBounds() -> Bounds {
        EffectiveLayer.bounds(model: model.properties, presentation: presentation)
    }

    package func effectivePosition() -> Point2D {
        EffectiveLayer.position(model: model.properties, presentation: presentation)
    }

    package func effectiveAnchorPoint() -> Point2D {
        EffectiveLayer.anchorPoint(model: model.properties, presentation: presentation)
    }

    package func effectiveScrollOffset() -> Point2D {
        presentation.override_?.scrollOffset ?? model.properties.scrollOffset
    }

    package func effectiveOpacity() -> Float {
        EffectiveLayer.opacity(model: model.properties, presentation: presentation)
    }

    package func effectiveCornerRadii() -> Float4 {
        EffectiveLayer.cornerRadii(model: model, presentation: presentation)
    }

    /// Renderer-authoritative content for this layer. Mirrors `presentedContent`.
    package func presentedContent() -> LayerContent {
        presentation.content
    }

    /// Whether this layer draws anything that contributes its own extent (vs
    /// being a pure structural container). Mirrors `layerContributesOwnExtent`.
    package func contributesOwnExtent() -> Bool {
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
package enum LayerTreeError: Error, Equatable, Sendable {
    case missingLayer
    case missingParentLayer
    case layerCycle
}

/// The retained layer tree: an id→node map plus the ordered root child list.
/// Mirrors `RenderLayer.LayerTree`.
package struct LayerTree: Sendable {
    package var layers: [UInt64: Layer] = [:]
    /// Ordered root layers per producer context. Remote-host expansion resolves
    /// the target context here, while the compositor frame starts from
    /// `compositorContextId`.
    package var contextRoots: [ContextID: [UInt64]] = [:]

    package init() {}

    /// Read a node by id. Mirrors `get`.
    package func get(_ id: UInt64) -> Layer? {
        layers[id]
    }

    /// Insert (or replace) a node keyed by its id. Mirrors `insertLayer`.
    package mutating func insertLayer(_ node: Layer) {
        layers[node.id] = node
    }

    /// Detach `id` from its parent (or the root list) and clear its parent
    /// pointer. No-op if absent. Mirrors `detach`.
    package mutating func detach(_ id: UInt64) {
        var ignored: UInt64 = 0
        detach(id, dictionaryProbes: &ignored)
    }

    package mutating func detach(
        _ id: UInt64,
        dictionaryProbes: inout UInt64
    ) {
        dictionaryProbes &+= 1
        guard let childIndex = layers.index(forKey: id) else { return }
        detach(
            id,
            at: childIndex,
            dictionaryProbes: &dictionaryProbes)
    }

    private mutating func detach(
        _ id: UInt64,
        at childIndex: Dictionary<UInt64, Layer>.Index,
        dictionaryProbes: inout UInt64
    ) {
        let parentID = layers.values[childIndex].parent
        let rootContext = layers.values[childIndex].rootContext
        if let parentID {
            dictionaryProbes &+= 1
            if let parentIndex = layers.index(forKey: parentID) {
                var parent = MutableRef(&layers.values[parentIndex])
                parent.value.children.removeAll { $0 == id }
            }
        }
        if let rootContext {
            dictionaryProbes &+= 1
            if let rootIndex = contextRoots.index(forKey: rootContext) {
                contextRoots.values[rootIndex].removeAll { $0 == id }
                if contextRoots.values[rootIndex].isEmpty {
                    contextRoots.remove(at: rootIndex)
                }
            }
        }
        var child = MutableRef(&layers.values[childIndex])
        child.value.parent = nil
        child.value.rootContext = nil
    }

    /// Detach `id` and remove it from the map. No-op if absent. Mirrors
    /// `removeLayer`.
    package mutating func removeLayer(_ id: UInt64) {
        var ignored: UInt64 = 0
        removeLayer(id, dictionaryProbes: &ignored)
    }

    package mutating func removeLayer(
        _ id: UInt64,
        dictionaryProbes: inout UInt64
    ) {
        dictionaryProbes &+= 1
        guard layers.index(forKey: id) != nil else { return }
        var pending = [id]
        var subtree: [UInt64] = []
        var visited: Set<UInt64> = []
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            dictionaryProbes &+= 1
            guard let index = layers.index(forKey: current) else { continue }
            subtree.append(current)
            pending.append(contentsOf: layers.values[index].children)
        }
        // Detach the subtree root from external structure. Descendants are all
        // removed together, so walking each parent array would only add quadratic work.
        detach(id, dictionaryProbes: &dictionaryProbes)
        for nodeID in subtree {
            dictionaryProbes &+= 1
            layers.removeValue(forKey: nodeID)
        }
    }

    /// Attach `id` as a root child at `index` (clamped). The node must exist.
    /// Mirrors `attachRoot`.
    package mutating func attachRoot(_ id: UInt64, index: Int, contextId: ContextID) throws {
        guard let childIndex = layers.index(forKey: id) else {
            throw LayerTreeError.missingLayer
        }
        var ignored: UInt64 = 0
        attachRoot(
            id,
            at: childIndex,
            index: index,
            contextId: contextId,
            dictionaryProbes: &ignored)
    }

    package mutating func attachRootValidated(
        _ id: UInt64,
        index: Int,
        contextId: ContextID,
        dictionaryProbes: inout UInt64
    ) {
        dictionaryProbes &+= 1
        guard let childIndex = layers.index(forKey: id) else {
            preconditionFailure("validated root attachment references a missing layer")
        }
        attachRoot(
            id,
            at: childIndex,
            index: index,
            contextId: contextId,
            dictionaryProbes: &dictionaryProbes)
    }

    private mutating func attachRoot(
        _ id: UInt64,
        at childIndex: Dictionary<UInt64, Layer>.Index,
        index: Int,
        contextId: ContextID,
        dictionaryProbes: inout UInt64
    ) {
        detach(
            id,
            at: childIndex,
            dictionaryProbes: &dictionaryProbes)
        dictionaryProbes &+= 1
        if let rootIndex = contextRoots.index(forKey: contextId) {
            let insertionIndex = min(
                max(0, index),
                contextRoots.values[rootIndex].count)
            contextRoots.values[rootIndex].insert(id, at: insertionIndex)
        } else {
            dictionaryProbes &+= 1
            contextRoots[contextId] = [id]
        }
        var child = MutableRef(&layers.values[childIndex])
        child.value.rootContext = contextId
    }

    /// Ordered roots for a context.
    package func roots(for contextId: ContextID) -> [UInt64] {
        contextRoots[contextId] ?? []
    }

    /// Whether `id` is attached beneath a root owned by `contextId`. Explicit
    /// presentation entry roots may be nested placement layers, so ownership is
    /// established by walking their parent chain to the context root.
    package func contains(_ id: UInt64, in contextId: ContextID) -> Bool {
        var cursor: UInt64? = id
        var visited = Set<UInt64>()
        while let current = cursor,
            visited.insert(current).inserted,
            let layer = layers[current]
        {
            if layer.rootContext == contextId { return true }
            cursor = layer.parent
        }
        return false
    }

    /// Attach `childId` under `parentId` at `index` (clamped), refusing to
    /// create a cycle. Both nodes must exist. Mirrors `attachChild`.
    package mutating func attachChild(parentId: UInt64, childId: UInt64, index: Int) throws {
        guard let parentIndex = layers.index(forKey: parentId) else {
            throw LayerTreeError.missingParentLayer
        }
        guard let childIndex = layers.index(forKey: childId) else {
            throw LayerTreeError.missingLayer
        }
        if wouldCreateCycle(childId: childId, parentId: parentId) {
            throw LayerTreeError.layerCycle
        }
        var ignored: UInt64 = 0
        attachChild(
            parentId: parentId,
            at: parentIndex,
            childId: childId,
            at: childIndex,
            index: index,
            dictionaryProbes: &ignored)
    }

    package mutating func attachChildValidated(
        parentId: UInt64,
        childId: UInt64,
        index: Int,
        dictionaryProbes: inout UInt64
    ) {
        dictionaryProbes &+= 2
        guard let childIndex = layers.index(forKey: childId),
            let parentIndex = layers.index(forKey: parentId)
        else {
            preconditionFailure("validated child attachment references a missing layer")
        }
        attachChild(
            parentId: parentId,
            at: parentIndex,
            childId: childId,
            at: childIndex,
            index: index,
            dictionaryProbes: &dictionaryProbes)
    }

    private mutating func attachChild(
        parentId: UInt64,
        at parentIndex: Dictionary<UInt64, Layer>.Index,
        childId: UInt64,
        at childIndex: Dictionary<UInt64, Layer>.Index,
        index: Int,
        dictionaryProbes: inout UInt64
    ) {
        detach(
            childId,
            at: childIndex,
            dictionaryProbes: &dictionaryProbes)
        var child = MutableRef(&layers.values[childIndex])
        child.value.parent = parentId
        child.value.rootContext = nil
        let insertionIndex = min(
            max(0, index),
            layers.values[parentIndex].children.count)
        var parent = MutableRef(&layers.values[parentIndex])
        parent.value.children.insert(childId, at: insertionIndex)
    }

    /// True when attaching `childId` under `parentId` would form a cycle (i.e.
    /// `childId` is `parentId` or an ancestor of it). Mirrors `wouldCreateCycle`.
    package func wouldCreateCycle(childId: UInt64, parentId: UInt64) -> Bool {
        if childId == parentId { return true }
        var cursor: UInt64? = parentId
        var visited = Set<UInt64>()
        while let id = cursor {
            if id == childId { return true }
            guard visited.insert(id).inserted,
                let layer = layers[id]
            else {
                return true
            }
            cursor = layer.parent
        }
        return false
    }
}
