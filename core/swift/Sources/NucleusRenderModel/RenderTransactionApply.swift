// The authoritative retained-layer transaction and applier.
//
// Structural and model mutations define the retained tree:
// create/update nodes, detach, insert (with the root + cycle-fallback routing),
// remove, and the sparse property writes (position/anchor/transform/opacity/
// bounds/clip/scroll, the visual-style + shadow + content deltas, the compound
// frame, content-sample + background-effect, backdrop attachment), plus
// revision and damage bookkeeping. `RenderTransactionLowering` produces these
// transactions and `RetainedTreeStore` applies them.

// MARK: - Well-known context ids

/// The compositor's own producer slot. Mirrors `compositor_context_id`.
public let compositorContextId = ContextID(raw: 63)
/// The shell-overlay producer slot.
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
/// clear, `.some(value)` = replace.
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
    /// Layer-local logical damage for a paint replacement. `nil` means the
    /// replacement affects the complete layer bounds.
    public var contentDamage: Rect?
    public var backdropAttachment: BackdropAttachment??
    public var contentSample: ContentSample?
    public var backgroundEffect: Bool?
    public var backgroundEffectRegions: BackgroundEffectRegions?
    public var frame: Frame?
    public var usesDefaultFrameAction = false
    public var usesDefaultOpacityAction = false

    public init(nodeId: UInt64) { self.nodeId = nodeId }
}

/// One producer commit: structural, property, and animation deltas for one
/// context.
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
    public var animationsAdded: [AnimationRecord] = []
    public var animationsRemoved: [AnimationRemoval] = []
    public var animationBeginTimeSeconds: Double = 0
    public var animationBeginTimePending = false
    /// Completion token fired once every animation created by this transaction
    /// finishes. `0` = none.
    public var completionToken: UInt64 = 0

    public init(contextId: ContextID) { self.contextId = contextId }

    /// True when the transaction carries no deltas.
    public var isEmpty: Bool {
        created.isEmpty && inserted.isEmpty && removed.isEmpty &&
            detached.isEmpty && propertyUpdates.isEmpty &&
            animationsAdded.isEmpty && animationsRemoved.isEmpty &&
            completionToken == 0
    }
}

// MARK: - Applier

/// Folds a committed `Transaction` into a `LayerTree`. Mirrors the retained-model
/// core of `applyTransaction`.
public enum TransactionApplier: Sendable {
    public enum ApplyError: Error, Equatable, Sendable {
        case insertion(nodeID: UInt64, parentID: UInt64, reason: LayerTreeError)
        case propertyUpdateMissingLayer(nodeID: UInt64)
        case invalidTopology(nodeID: UInt64)
    }

    /// Per-commit work counters used by retained-tree benchmarks.
    public struct ApplyDiagnostics: Equatable, Sendable {
        public fileprivate(set) var validationNodesVisited: UInt64 = 0
        public fileprivate(set) var validationAncestorSteps: UInt64 = 0
        public fileprivate(set) var applyDictionaryProbes: UInt64 = 0

        public init() {}
    }

    private enum ParentOverride {
        case root
        case parent(UInt64)
    }

    private enum ParentLookup {
        case known(UInt64?)
        case missing
    }

    /// The transaction-local final topology. Unchanged parent links are read
    /// lazily from the retained tree; no full-tree shadow is constructed.
    private struct ValidationTopology {
        let tree: LayerTree
        let createdIDs: Set<UInt64>
        var parentOverrides: [UInt64: ParentOverride] = [:]

        func contains(
            _ id: UInt64,
            diagnostics: inout ApplyDiagnostics
        ) -> Bool {
            if createdIDs.contains(id) {
                return true
            }
            diagnostics.validationNodesVisited &+= 1
            return tree.layers.index(forKey: id) != nil
        }

        func parent(
            of id: UInt64,
            diagnostics: inout ApplyDiagnostics
        ) -> ParentLookup {
            if let override = parentOverrides[id] {
                switch override {
                case .root:
                    return .known(nil)
                case .parent(let parentID):
                    return .known(parentID)
                }
            }

            diagnostics.validationNodesVisited &+= 1
            if let index = tree.layers.index(forKey: id) {
                return .known(tree.layers.values[index].parent)
            }
            if createdIDs.contains(id) {
                return .known(nil)
            }
            return .missing
        }
    }

    /// Applies atomically. Invalid producer structure leaves the authoritative tree unchanged.
    @discardableResult
    public static func apply(_ txn: Transaction, to tree: inout LayerTree) -> Result<Void, ApplyError> {
        var diagnostics = ApplyDiagnostics()
        return apply(txn, to: &tree, diagnostics: &diagnostics)
    }

    /// Applies atomically and reports the amount of retained topology inspected
    /// and the dictionary work performed while applying the commit.
    @discardableResult
    public static func apply(
        _ txn: Transaction,
        to tree: inout LayerTree,
        diagnostics: inout ApplyDiagnostics
    ) -> Result<Void, ApplyError> {
        diagnostics = ApplyDiagnostics()
        do {
            try validate(txn, against: tree, diagnostics: &diagnostics)
            applyValidated(txn, to: &tree, diagnostics: &diagnostics)
            return .success(())
        } catch let error {
            return .failure(error)
        }
    }

    /// Validate against transaction-local parent overrides. Copying the retained
    /// `LayerTree` here is constant-time; its dictionaries remain shared and are
    /// only read along touched ancestor chains.
    private static func validate(
        _ txn: Transaction,
        against tree: LayerTree,
        diagnostics: inout ApplyDiagnostics
    ) throws(ApplyError) {
        var topology = ValidationTopology(
            tree: tree,
            createdIDs: Set(txn.created.lazy.map(\.nodeId)))

        // Application detaches every node before processing insertions.
        for detachment in txn.detached
        where topology.contains(
            detachment.nodeId,
            diagnostics: &diagnostics)
        {
            topology.parentOverrides[detachment.nodeId] = .root
        }

        // Insertions are ordered writes to the final parent relation.
        for insertion in txn.inserted {
            guard topology.contains(
                insertion.nodeId,
                diagnostics: &diagnostics)
            else {
                throw ApplyError.insertion(
                    nodeID: insertion.nodeId,
                    parentID: insertion.parentId,
                    reason: .missingLayer)
            }
            if insertion.parentId != 0 {
                var ancestor: UInt64? = insertion.parentId
                var visited: Set<UInt64> = []
                while let current = ancestor {
                    diagnostics.validationAncestorSteps &+= 1
                    if current == insertion.nodeId {
                        throw ApplyError.insertion(
                            nodeID: insertion.nodeId,
                            parentID: insertion.parentId,
                            reason: .layerCycle)
                    }
                    guard visited.insert(current).inserted else {
                        throw ApplyError.invalidTopology(nodeID: current)
                    }
                    switch topology.parent(
                        of: current,
                        diagnostics: &diagnostics)
                    {
                    case .known(let parent):
                        ancestor = parent
                    case .missing:
                        if current == insertion.parentId {
                            throw ApplyError.insertion(
                                nodeID: insertion.nodeId,
                                parentID: insertion.parentId,
                                reason: .missingParentLayer)
                        }
                        throw ApplyError.invalidTopology(nodeID: current)
                    }
                }
            }
            topology.parentOverrides[insertion.nodeId] =
                insertion.parentId == 0
                ? .root
                : .parent(insertion.parentId)
        }

        // Removals delete their final descendants. Determine membership by
        // walking each updated node upward rather than materializing the
        // complete final child graph.
        let removalRoots = Set(txn.removed.lazy.map(\.nodeId))
        for update in txn.propertyUpdates {
            var current: UInt64? = update.nodeId
            var visited: Set<UInt64> = []
            while let nodeID = current {
                diagnostics.validationAncestorSteps &+= 1
                if removalRoots.contains(nodeID) {
                    throw ApplyError.propertyUpdateMissingLayer(
                        nodeID: update.nodeId)
                }
                guard visited.insert(nodeID).inserted else {
                    throw ApplyError.invalidTopology(nodeID: nodeID)
                }
                switch topology.parent(
                    of: nodeID,
                    diagnostics: &diagnostics)
                {
                case .known(let parent):
                    current = parent
                case .missing:
                    if nodeID == update.nodeId {
                        throw ApplyError.propertyUpdateMissingLayer(
                            nodeID: update.nodeId)
                    }
                    throw ApplyError.invalidTopology(nodeID: nodeID)
                }
            }
        }
    }

    private static func applyValidated(
        _ txn: Transaction,
        to tree: inout LayerTree,
        diagnostics: inout ApplyDiagnostics
    ) {
        // Pass 1: create or update node records (no hierarchy wiring yet).
        for created in txn.created {
            applyCreated(
                created,
                to: &tree,
                dictionaryProbes: &diagnostics.applyDictionaryProbes)
        }
        // Pass 2: detaches before rewiring hierarchy.
        for d in txn.detached {
            tree.detach(
                d.nodeId,
                dictionaryProbes: &diagnostics.applyDictionaryProbes)
        }
        // Pass 3: wire parent/child relationships. Only parent zero denotes a root;
        // missing parents and cycles reject the whole transaction.
        for ins in txn.inserted {
            let idx = Int(ins.index)
            if ins.parentId == 0 {
                tree.attachRootValidated(
                    ins.nodeId,
                    index: idx,
                    contextId: txn.contextId,
                    dictionaryProbes: &diagnostics.applyDictionaryProbes)
            } else {
                tree.attachChildValidated(
                    parentId: ins.parentId,
                    childId: ins.nodeId,
                    index: idx,
                    dictionaryProbes: &diagnostics.applyDictionaryProbes)
            }
        }
        // Pass 4: removals.
        for r in txn.removed {
            tree.removeLayer(
                r.nodeId,
                dictionaryProbes: &diagnostics.applyDictionaryProbes)
        }
        // Pass 5: sparse property updates.
        for pu in txn.propertyUpdates {
            diagnostics.applyDictionaryProbes &+= 1
            guard let index = tree.layers.index(forKey: pu.nodeId) else {
                continue
            }
            var node = MutableRef(&tree.layers.values[index])
            applyPropertyUpdate(pu, to: &node.value)
        }
    }

    // MARK: Created

    private static func applyCreated(
        _ created: LayerCreated,
        to tree: inout LayerTree,
        dictionaryProbes: inout UInt64
    ) {
        let initialContent = created.initialContent.resolved()
        let hasPaint: Bool = { if case .paint = initialContent { return true }; return false }()
        let id = created.nodeId

        dictionaryProbes &+= 1
        if let index = tree.layers.index(forKey: id) {
            // Existing node — update properties.
            var node = MutableRef(&tree.layers.values[index])
            let boundsChanged =
                node.value.model.properties.bounds.w != created.bounds.w ||
                node.value.model.properties.bounds.h != created.bounds.h
            node.value.kind = created.kind
            node.value.role = created.role
            node.value.backdropAttachment = created.backdropAttachment
            node.value.model.properties.position = created.position
            node.value.model.properties.anchorPoint = created.anchorPoint
            node.value.model.properties.transform = created.transform
            node.value.model.properties.opacity = created.opacity
            node.value.model.properties.clip = created.clip
            node.value.model.properties.bounds = created.bounds
            node.value.model.visualStyle = created.visualStyle
            if boundsChanged {
                node.value.model.visualRevision &+= 1
                node.value.model.compositeRevision &+= 1
            }
            if case .none = initialContent {
                // No content supplied; leave existing content untouched.
            } else {
                node.value.model.content = initialContent
                node.value.presentation.content = initialContent
                node.value.damage.markContent(nil)
            }
            node.value.damage.flags.structure = true
            if boundsChanged {
                node.value.damage.flags.backingReallocate = true
                if case .paint = node.value.model.content {
                    node.value.damage.markContent(nil)
                }
            }
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
            if hasPaint {
                node.damage.markContent(nil)
            }
            node.damage.flags.structure = true
            dictionaryProbes &+= 1
            tree.insertLayer(node)
        }
    }

    // MARK: Property update

    private static func applyPropertyUpdate(_ pu: LayerPropertyUpdate, to node: inout Layer) {
        let priorProperties = node.model.properties
        let priorVisualStyle = node.model.visualStyle
        let priorBackdropAttachment = node.backdropAttachment
        let priorContentSample = node.presentation.contentSample
        let priorBackgroundEffect = node.presentation.backgroundEffect
        let priorBackgroundEffectRegions =
            node.presentation.backgroundEffectRegions
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
                if node.model.properties.clip != nil {
                    node.model.properties.clip!.rect.2 = b.w
                    node.model.properties.clip!.rect.3 = b.h
                }
                if case .paint = node.model.content {
                    node.damage.flags.backingReallocate = true
                    node.damage.markContent(nil)
                }
            }
        }
        if let so = pu.scrollOffset { node.model.properties.scrollOffset = so }

        applyVisualStyleDelta(pu.visualStyle, to: &node)
        applyShadowDelta(pu.shadow, to: &node)
        applyContentDelta(
            pu.content,
            localDamage: pu.contentDamage,
            to: &node)

        if let sample = pu.contentSample {
            node.presentation.contentSample = sample
            node.damage.markContent(nil)
        } else if case .none = pu.content {
            node.presentation.contentSample = ContentSample()
        }

        if let f = pu.frame {
            applyFrame(f, to: &node)
        }

        let compositeChanged =
            node.model.properties != priorProperties
                || node.model.visualStyle != priorVisualStyle
                || node.backdropAttachment != priorBackdropAttachment
                || node.presentation.contentSample != priorContentSample
                || node.presentation.backgroundEffect
                    != priorBackgroundEffect
                || node.presentation.backgroundEffectRegions
                    != priorBackgroundEffectRegions
        if compositeChanged {
            node.model.visualRevision &+= 1
            node.model.compositeRevision &+= 1
            node.damage.flags.property = true
        }
    }

    /// Visual-style delta: a `.set` equal to the current style is suppressed (no
    /// revision bump). Mirrors the `pu.visual_style` switch.
    private static func applyVisualStyleDelta(_ delta: VisualStyleDelta, to node: inout Layer) {
        switch delta {
        case .set(let style):
            if let current = node.model.visualStyle {
                if current != style {
                    node.model.visualStyle = style
                }
            } else {
                node.model.visualStyle = style
            }
        case .clear:
            if node.model.visualStyle != nil {
                node.model.visualStyle = nil
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
                }
            } else {
                var style = VisualStyle()
                style.shadow = newShadow
                node.model.visualStyle = style
            }
        case .clear:
            if node.model.visualStyle != nil, node.model.visualStyle!.shadow != nil {
                node.model.visualStyle!.shadow = nil
            }
        case .unchanged:
            break
        }
    }

    /// Content delta — writes `model.content` and the `presentation.content`
    /// mirror in lockstep. External/snapshot rebinds to the same handle are
    /// suppressed; paint always replaces. Mirrors the `pu.content` switch (minus
    /// the refcount retain/release, which is renderer-owned).
    private static func applyContentDelta(
        _ delta: ContentDelta,
        localDamage: Rect?,
        to node: inout Layer
    ) {
        switch delta {
        case .paint(let handle):
            if !handle.isNone {
                node.model.content = .paint(handle)
                node.presentation.content = .paint(handle)
                node.model.visualRevision &+= 1
                node.damage.markContent(localDamage)
            }
        case .external(let newId):
            let same: Bool = { if case .external(let cur) = node.model.content { return cur == newId }; return false }()
            if !same {
                node.model.content = .external(newId)
                node.presentation.content = .external(newId)
                node.model.visualRevision &+= 1
                node.damage.markContent(nil)
            }
        case .snapshot(let handle):
            let same: Bool = { if case .snapshot(let cur) = node.model.content { return cur == handle }; return false }()
            if !same {
                node.model.content = .snapshot(handle)
                node.presentation.content = .snapshot(handle)
                node.model.visualRevision &+= 1
                node.damage.markContent(nil)
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
            if node.model.properties.clip != nil {
                node.model.properties.clip!.rect.2 = newBounds.w
                node.model.properties.clip!.rect.3 = newBounds.h
            }
            if case .paint = node.model.content {
                node.damage.flags.backingReallocate = true
                node.damage.markContent(nil)
            }
        }
    }
}
