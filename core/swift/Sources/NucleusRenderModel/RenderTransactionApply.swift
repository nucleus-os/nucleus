// Phase 8.6 — Swift render transaction wire types + applier (retained-model core).
//
// The sixth slice of the render-server retained-layer model: the `Transaction`
// wire envelope and the `TransactionApplier` that folds one committed
// transaction into the Swift `LayerTree`.
//
// Scope — the structural + model mutations that define the retained tree:
// create/update nodes, detach, insert (with the root + cycle-fallback routing),
// remove, and the sparse property writes (position/anchor/transform/opacity/
// bounds/clip/scroll, the visual-style + shadow + content deltas, the compound
// frame, content-sample + background-effect, backdrop attachment), plus the
// `visual_revision` and `damage`-flag bookkeeping these produce.
//
// Excluded (co-lands with the renderer move, 10b): the render-server side
// effects — paint/snapshot refcount retain/release, backing alloc/free,
// presentation-transition capture + gate release, field fences, implicit-action
// expansion, animation records, and host-target-root tracking. Those touch
// renderer/animation state this dormant model does not own. Nothing
// imports this yet.

// MARK: - Well-known context ids

/// The compositor's own producer slot. Mirrors `compositor_context_id`.
public let compositorContextId = ContextID(raw: 63)
/// The shell-overlay producer slot (latest-wins coalescing target in the commit
/// queue). Mirrors `shell_overlay_context_id`.
public let shellOverlayContextId = ContextID(raw: 62)

// MARK: - Wire deltas

/// Compound position+bounds write applied atomically. Mirrors `animation.Frame`.
public struct Frame: Equatable, Sendable {
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float

    public init(left: Float, top: Float, right: Float, bottom: Float) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// Declare a new `Layer` with its initial property values. Mirrors
/// `LayerCreated`.
public struct LayerCreated: Sendable {
    public var nodeId: UInt64
    public var kind: LayerKind
    public var role: LayerRole = .generic
    public var backdropAttachment: BackdropAttachment?
    public var position = Point2D()
    public var anchorPoint = Point2D(x: 0.5, y: 0.5)
    public var transform = M44.identity
    public var opacity: Float = 1.0
    public var clip: ClipOp?
    public var bounds = Bounds()
    public var visualStyle: VisualStyle?
    public var initialContent: InitialContent = .none

    public init(
        nodeId: UInt64,
        kind: LayerKind,
        role: LayerRole = .generic,
        backdropAttachment: BackdropAttachment? = nil,
        position: Point2D = Point2D(),
        anchorPoint: Point2D = Point2D(x: 0.5, y: 0.5),
        transform: M44 = M44.identity,
        opacity: Float = 1.0,
        clip: ClipOp? = nil,
        bounds: Bounds = Bounds(),
        visualStyle: VisualStyle? = nil,
        initialContent: InitialContent = .none
    ) {
        self.nodeId = nodeId
        self.kind = kind
        self.role = role
        self.backdropAttachment = backdropAttachment
        self.position = position
        self.anchorPoint = anchorPoint
        self.transform = transform
        self.opacity = opacity
        self.clip = clip
        self.bounds = bounds
        self.visualStyle = visualStyle
        self.initialContent = initialContent
    }
}

/// Attach `nodeId` under `parentId` at `index`. Mirrors `LayerInserted`.
public struct LayerInserted: Sendable {
    public var nodeId: UInt64
    public var parentId: UInt64
    public var index: UInt32

    public init(nodeId: UInt64, parentId: UInt64, index: UInt32) {
        self.nodeId = nodeId
        self.parentId = parentId
        self.index = index
    }
}

/// Full removal — the layer ceases to exist. Mirrors `LayerRemoved`.
public struct LayerRemoved: Sendable {
    public var nodeId: UInt64

    public init(nodeId: UInt64) {
        self.nodeId = nodeId
    }
}

/// Parent detachment — the layer keeps identity, loses its tree place. Mirrors
/// `LayerDetached`.
public struct LayerDetached: Sendable {
    public var nodeId: UInt64

    public init(nodeId: UInt64) {
        self.nodeId = nodeId
    }
}

/// Sparse property write. Any field set to non-`nil` (or non-`.unchanged` for
/// deltas) is applied to `nodeId`'s model state. The `clip`/`backdropAttachment`
/// double-optionals: `nil` = no change, `.some(nil)` =
/// clear, `.some(value)` = replace. Mirrors the retained-model subset of
/// `LayerPropertyUpdate` (animation/transition/fence fields are excluded — see
/// the file header).
public struct LayerPropertyUpdate: Sendable {
    public var nodeId: UInt64
    public var position: Point2D?
    public var anchorPoint: Point2D?
    public var transform: M44?
    public var opacity: Float?
    public var bounds: Bounds?
    public var clip: ClipOp??
    public var scrollOffset: Point2D?
    public var visualStyle: VisualStyleDelta = .unchanged
    public var shadow: ShadowDelta = .unchanged
    public var content: ContentDelta = .unchanged
    public var backdropAttachment: BackdropAttachment??
    public var contentSample: ContentSample?
    public var backgroundEffect: Bool?
    public var backgroundEffectRegions: BackgroundEffectRegions?
    public var frame: Frame?

    public init(nodeId: UInt64) { self.nodeId = nodeId }
}

/// One producer commit: structural + property deltas for one context. Mirrors
/// the retained-model subset of `RenderTransaction.Transaction` (the
/// animation/fence delta arrays are excluded here — see the file header).
public struct Transaction: Sendable {
    public var contextId: ContextID
    public var revision: UInt64 = 0
    public var groupId: UInt64 = 0
    public var groupSeq: UInt32 = 0
    public var created: [LayerCreated] = []
    public var inserted: [LayerInserted] = []
    public var removed: [LayerRemoved] = []
    public var detached: [LayerDetached] = []
    public var propertyUpdates: [LayerPropertyUpdate] = []
    /// Completion token fired once every animation created by this transaction
    /// finishes. `0` = none. Carried for queue coalescing; the animation
    /// completion machinery co-lands with the renderer move (10b). Mirrors
    /// `completion_token`.
    public var completionToken: UInt64 = 0

    public init(contextId: ContextID) { self.contextId = contextId }

    /// True when the transaction carries no deltas. Mirrors `Transaction.isEmpty`
    /// (minus the animation/fence terms excluded from this port).
    public var isEmpty: Bool {
        created.isEmpty && inserted.isEmpty && removed.isEmpty &&
            detached.isEmpty && propertyUpdates.isEmpty && completionToken == 0
    }
}

// MARK: - Applier

/// Folds a committed `Transaction` into a `LayerTree`. Mirrors the retained-model
/// core of `applyTransaction`.
public enum TransactionApplier: Sendable {
    public enum ApplyError: Error, Equatable, Sendable {
        case insertion(nodeID: UInt64, parentID: UInt64, reason: LayerTreeError)
        case propertyUpdateMissingLayer(nodeID: UInt64)
    }

    /// Applies atomically. Invalid producer structure leaves the authoritative tree unchanged.
    @discardableResult
    public static func apply(_ txn: Transaction, to tree: inout LayerTree) -> Result<Void, ApplyError> {
        do {
            try validate(txn, against: tree)
            applyValidated(txn, to: &tree)
            return .success(())
        } catch let error as ApplyError {
            return .failure(error)
        } catch {
            preconditionFailure("unexpected transaction application error: \(error)")
        }
    }

    /// Validate against a lightweight topology shadow. Copying the full retained
    /// tree would trigger copy-on-write of every heavyweight Layer on each commit.
    private static func validate(_ txn: Transaction, against tree: LayerTree) throws {
        var parents = tree.layers.mapValues(\.parent)
        for created in txn.created where !parents.keys.contains(created.nodeId) {
            parents[created.nodeId] = .some(nil)
        }
        for insertion in txn.inserted {
            guard parents.keys.contains(insertion.nodeId) else {
                throw ApplyError.insertion(
                    nodeID: insertion.nodeId,
                    parentID: insertion.parentId,
                    reason: .missingLayer)
            }
            if insertion.parentId != 0 {
                guard parents.keys.contains(insertion.parentId) else {
                    throw ApplyError.insertion(
                        nodeID: insertion.nodeId,
                        parentID: insertion.parentId,
                        reason: .missingParentLayer)
                }
                var ancestor: UInt64? = insertion.parentId
                var visited: Set<UInt64> = []
                while let current = ancestor, visited.insert(current).inserted {
                    if current == insertion.nodeId {
                        throw ApplyError.insertion(
                            nodeID: insertion.nodeId,
                            parentID: insertion.parentId,
                            reason: .layerCycle)
                    }
                    ancestor = parents[current] ?? nil
                }
            }
            parents[insertion.nodeId] = .some(insertion.parentId == 0 ? nil : insertion.parentId)
        }

        var children: [UInt64: [UInt64]] = [:]
        for (nodeID, parent) in parents {
            if let parent { children[parent, default: []].append(nodeID) }
        }
        var removed: Set<UInt64> = []
        var pending = txn.removed.map(\.nodeId)
        while let nodeID = pending.popLast(), removed.insert(nodeID).inserted {
            pending.append(contentsOf: children[nodeID] ?? [])
        }
        for update in txn.propertyUpdates where removed.contains(update.nodeId) || !parents.keys.contains(update.nodeId) {
            throw ApplyError.propertyUpdateMissingLayer(nodeID: update.nodeId)
        }
    }

    private static func applyValidated(_ txn: Transaction, to tree: inout LayerTree) {
        // Pass 1: create or update node records (no hierarchy wiring yet).
        for created in txn.created {
            applyCreated(created, to: &tree)
        }
        // Pass 2: detaches before rewiring hierarchy.
        for d in txn.detached {
            tree.detach(d.nodeId)
        }
        // Pass 3: wire parent/child relationships. Only parent zero denotes a root;
        // missing parents and cycles reject the whole transaction.
        for ins in txn.inserted {
            let idx = Int(ins.index)
            if ins.parentId == 0 {
                try! tree.attachRoot(ins.nodeId, index: idx, contextId: txn.contextId)
            } else {
                try! tree.attachChild(parentId: ins.parentId, childId: ins.nodeId, index: idx)
            }
        }
        // Pass 4: removals.
        for r in txn.removed {
            tree.removeLayer(r.nodeId)
        }
        // Pass 5: sparse property updates.
        for pu in txn.propertyUpdates {
            guard var node = tree.layers[pu.nodeId] else { continue }
            applyPropertyUpdate(pu, to: &node)
            tree.layers[pu.nodeId] = node
        }
    }

    // MARK: Created

    private static func applyCreated(_ created: LayerCreated, to tree: inout LayerTree) {
        let initialContent = created.initialContent.resolved()
        let hasPaint: Bool = { if case .paint = initialContent { return true }; return false }()
        let id = created.nodeId

        if var node = tree.layers[id] {
            // Existing node — update properties.
            let boundsChanged = node.model.properties.bounds.w != created.bounds.w ||
                node.model.properties.bounds.h != created.bounds.h
            node.kind = created.kind
            node.role = created.role
            node.backdropAttachment = created.backdropAttachment
            node.model.properties.position = created.position
            node.model.properties.anchorPoint = created.anchorPoint
            node.model.properties.transform = created.transform
            node.model.properties.opacity = created.opacity
            node.model.properties.clip = created.clip
            node.model.properties.bounds = created.bounds
            node.model.visualStyle = created.visualStyle
            if boundsChanged { node.model.visualRevision &+= 1 }
            if case .none = initialContent {
                // No content supplied; leave existing content untouched.
            } else {
                node.model.content = initialContent
                node.presentation.content = initialContent
                node.damage.flags.content = true
            }
            node.damage.flags.structure = true
            if boundsChanged {
                node.damage.flags.backingReallocate = true
                if case .paint = node.model.content { node.damage.flags.content = true }
            }
            tree.layers[id] = node
        } else {
            // New node.
            var node = Layer(id: id, kind: created.kind)
            node.role = created.role
            node.backdropAttachment = created.backdropAttachment
            node.model.properties.position = created.position
            node.model.properties.anchorPoint = created.anchorPoint
            node.model.properties.transform = created.transform
            node.model.properties.opacity = created.opacity
            node.model.properties.clip = created.clip
            node.model.properties.bounds = created.bounds
            node.model.visualStyle = created.visualStyle
            node.model.content = initialContent
            node.presentation.content = initialContent
            node.damage.flags.content = hasPaint
            node.damage.flags.structure = true
            tree.insertLayer(node)
        }
    }

    // MARK: Property update

    private static func applyPropertyUpdate(_ pu: LayerPropertyUpdate, to node: inout Layer) {
        if let p = pu.position { node.model.properties.position = p }
        if let a = pu.anchorPoint { node.model.properties.anchorPoint = a }
        if let t = pu.transform { node.model.properties.transform = t }
        if let o = pu.opacity { node.model.properties.opacity = o }
        if let attachmentOpt = pu.backdropAttachment { node.backdropAttachment = attachmentOpt }
        if let bg = pu.backgroundEffect { node.presentation.backgroundEffect = bg }
        if let regions = pu.backgroundEffectRegions { node.presentation.backgroundEffectRegions = regions }
        if let clipOpt = pu.clip { node.model.properties.clip = clipOpt }

        if let b = pu.bounds {
            if b.w != node.model.properties.bounds.w || b.h != node.model.properties.bounds.h {
                node.model.properties.bounds = b
                node.model.visualRevision &+= 1
                if node.model.properties.clip != nil {
                    node.model.properties.clip!.rect.2 = b.w
                    node.model.properties.clip!.rect.3 = b.h
                }
                if case .paint = node.model.content {
                    node.damage.flags.backingReallocate = true
                    node.damage.flags.content = true
                }
            }
        }
        if let so = pu.scrollOffset { node.model.properties.scrollOffset = so }

        applyVisualStyleDelta(pu.visualStyle, to: &node)
        applyShadowDelta(pu.shadow, to: &node)
        applyContentDelta(pu.content, to: &node)

        if let sample = pu.contentSample {
            node.presentation.contentSample = sample
            node.damage.flags.content = true
        } else if case .none = pu.content {
            node.presentation.contentSample = ContentSample()
        }

        if let f = pu.frame {
            applyFrame(f, to: &node)
        }

        node.damage.flags.property = true
    }

    /// Visual-style delta: a `.set` equal to the current style is suppressed (no
    /// revision bump). Mirrors the `pu.visual_style` switch.
    private static func applyVisualStyleDelta(_ delta: VisualStyleDelta, to node: inout Layer) {
        switch delta {
        case .set(let style):
            if let current = node.model.visualStyle {
                if current != style {
                    node.model.visualStyle = style
                    node.model.visualRevision &+= 1
                }
            } else {
                node.model.visualStyle = style
                node.model.visualRevision &+= 1
            }
        case .clear:
            if node.model.visualStyle != nil {
                node.model.visualStyle = nil
                node.model.visualRevision &+= 1
            }
        case .unchanged:
            break
        }
    }

    /// Independent shadow delta — applied AFTER the visual-style replace, so a
    /// single update can replace the style then patch the shadow. Adding a
    /// shadow to a layer with no style creates a default-initialized style.
    /// Mirrors the `pu.shadow` switch.
    private static func applyShadowDelta(_ delta: ShadowDelta, to node: inout Layer) {
        switch delta {
        case .set(let newShadow):
            if node.model.visualStyle != nil {
                let same = node.model.visualStyle!.shadow == newShadow
                if !same {
                    node.model.visualStyle!.shadow = newShadow
                    node.model.visualRevision &+= 1
                }
            } else {
                var style = VisualStyle()
                style.shadow = newShadow
                node.model.visualStyle = style
                node.model.visualRevision &+= 1
            }
        case .clear:
            if node.model.visualStyle != nil, node.model.visualStyle!.shadow != nil {
                node.model.visualStyle!.shadow = nil
                node.model.visualRevision &+= 1
            }
        case .unchanged:
            break
        }
    }

    /// Content delta — writes `model.content` and the `presentation.content`
    /// mirror in lockstep. External/snapshot rebinds to the same handle are
    /// suppressed; paint always replaces. Mirrors the `pu.content` switch (minus
    /// the refcount retain/release, which is renderer-owned).
    private static func applyContentDelta(_ delta: ContentDelta, to node: inout Layer) {
        switch delta {
        case .paint(let handle):
            if !handle.isNone {
                node.model.content = .paint(handle)
                node.presentation.content = .paint(handle)
                node.model.visualRevision &+= 1
                node.damage.flags.content = true
            }
        case .external(let newId):
            let same: Bool = { if case .external(let cur) = node.model.content { return cur == newId }; return false }()
            if !same {
                node.model.content = .external(newId)
                node.presentation.content = .external(newId)
                node.model.visualRevision &+= 1
                node.damage.flags.content = true
            }
        case .snapshot(let handle):
            let same: Bool = { if case .snapshot(let cur) = node.model.content { return cur == handle }; return false }()
            if !same {
                node.model.content = .snapshot(handle)
                node.presentation.content = .snapshot(handle)
                node.model.visualRevision &+= 1
                node.damage.flags.content = true
            }
        case .none:
            if case .none = node.model.content {
                // already cleared
            } else {
                node.model.content = .none
                node.presentation.content = .none
                node.model.visualRevision &+= 1
            }
        case .unchanged:
            break
        }
    }

    /// Compound frame write — position + bounds atomically, with the same
    /// bounds-change side effects as a `bounds` write. Mirrors the `pu.frame`
    /// block.
    private static func applyFrame(_ f: Frame, to node: inout Layer) {
        let newPosition = Point2D(x: f.left, y: f.top)
        let newBounds = Bounds(w: f.right - f.left, h: f.bottom - f.top)
        let boundsChanged = node.model.properties.bounds.w != newBounds.w ||
            node.model.properties.bounds.h != newBounds.h
        node.model.properties.position = newPosition
        node.model.properties.bounds = newBounds
        if boundsChanged {
            node.model.visualRevision &+= 1
            if node.model.properties.clip != nil {
                node.model.properties.clip!.rect.2 = newBounds.w
                node.model.properties.clip!.rect.3 = newBounds.h
            }
            if case .paint = node.model.content {
                node.damage.flags.backingReallocate = true
                node.damage.flags.content = true
            }
        }
    }
}
