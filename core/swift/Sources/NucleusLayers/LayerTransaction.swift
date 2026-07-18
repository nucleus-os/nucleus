import NucleusTypes

public struct EncodedTransaction: Sendable {
    public var contextID: ContextID
    public var transactionID: UInt64
    public var groupID: UInt64
    public var groupSequence: UInt32
    public var revision: UInt32
    public var predictedPresentationNanoseconds: UInt64
    public var targetPresentationNanoseconds: UInt64
    public var completionToken: UInt64
    public var fences: [FenceRecord]
    public var created: [(LayerID, LayerDescriptor)]
    public var inserted: [(layer: LayerID, parent: LayerID?, index: UInt32)]
    public var removed: [LayerID]
    public var detached: [LayerID]
    public var propertyUpdates: [(layer: LayerID, properties: LayerPropertyUpdate)]
    public var animationsAdded: [(layer: LayerID, animation: Animation)]
    public var animationsRemoved: [(layer: LayerID, keyPath: AnimationKeyPath)]
    public var transitions: [TransitionRecord]
}

@MainActor
public protocol CommitSink: AnyObject {
    var resourceHostHandle: UInt64 { get }

    func commit(_ transaction: EncodedTransaction) throws(LayerError)
}

@MainActor
public final class InMemoryCommitSink: CommitSink, ~Sendable {
    public private(set) var transactions: [EncodedTransaction] = []
    public let resourceHostHandle: UInt64 = 0

    public init() {
    }

    public func commit(_ transaction: EncodedTransaction) throws(LayerError) {
        transactions.append(transaction)
    }
}

// The production render commit sink lives outside NucleusLayers so consumers
// that don't bridge to the compositor never reference production host wiring.

public enum CommitEncoder {
    @MainActor
    public static func encode(_ transaction: borrowing LayerTransaction) -> EncodedTransaction {
        transaction.encoded()
    }
}

#if NUCLEUS_LAYERS_PUBLIC_NAMES
public typealias Transaction = LayerTransaction
#endif

@MainActor
public struct LayerTransaction: ~Copyable, ~Sendable {
    public let context: Context
    public var transactionID: UInt64
    public var groupID: UInt64
    public var groupSequence: UInt32
    public var predictedPresentationNanoseconds: UInt64
    public var targetPresentationNanoseconds: UInt64
    public var completionToken: UInt64
    public var fences: [FenceRecord]
    public var transitions: [TransitionRecord]
    package var mutations: [LayerMutation]
    private var completed: Bool

    public init(
        context: Context,
        transactionID: UInt64 = 0,
        groupID: UInt64 = 0,
        groupSequence: UInt32 = 0,
        predictedPresentationNanoseconds: UInt64 = 0,
        targetPresentationNanoseconds: UInt64 = 0,
        completionToken: UInt64 = 0,
        fences: [FenceRecord] = [],
        transitions: [TransitionRecord] = []
    ) {
        self.context = context
        self.transactionID = transactionID
        if groupID == 0, let activeGroup = context.activeGroup {
            self.groupID = activeGroup.id
            self.groupSequence = activeGroup.allocateSequence()
        } else {
            self.groupID = groupID
            self.groupSequence = groupSequence
        }
        self.predictedPresentationNanoseconds = predictedPresentationNanoseconds
        self.targetPresentationNanoseconds = targetPresentationNanoseconds
        self.completionToken = completionToken
        self.fences = fences
        self.transitions = transitions
        self.mutations = []
        self.completed = false
    }

    /// Adds a per-field hold on `layer.field`. Subsequent property writes
    /// to that field on that layer are deferred at the consumer until the
    /// producer signals the matching `generation` token. Pillar F: typed
    /// per-field gating instead of a transaction-wide bitmask.
    public mutating func addFenceHold(
        field: FenceField, layer: Layer, generation: UInt64
    ) throws(LayerError) {
        try requireSameContext(layer)
        fences.append(FenceRecord(
            kind: .fieldHold,
            scopeField: field,
            scopeNodeId: layer.id.rawValue,
            generation: generation
        ))
    }

    /// Adds a content-generation hold. Presentation defers reading new
    /// content for `layer` until a content commit with `generation`
    /// arrives — the to-content-readiness gate that keeps a slow client's
    /// late commit from popping in instead of crossfading.
    public mutating func addContentGenerationHold(
        layer: Layer, generation: UInt64
    ) throws(LayerError) {
        try requireSameContext(layer)
        fences.append(FenceRecord(
            kind: .contentGenerationHold,
            scopeField: .content,
            scopeNodeId: layer.id.rawValue,
            generation: generation
        ))
    }

    /// Adds an action hold on the targeted scope. Default-action expansion
    /// for `field` on `layer` is suppressed until release — used when a
    /// producer authors a value but wants to suppress the implicit
    /// animation that would otherwise expand for that update.
    public mutating func addActionHold(
        field: FenceField, layer: Layer, generation: UInt64
    ) throws(LayerError) {
        try requireSameContext(layer)
        fences.append(FenceRecord(
            kind: .actionHold,
            scopeField: field,
            scopeNodeId: layer.id.rawValue,
            generation: generation
        ))
    }

    @discardableResult
    public mutating func beginTransition(
        layer: Layer,
        kind: TransitionKind = .crossfade,
        operationID: UInt64 = 0,
        generation: UInt64? = nil,
        duration: Double,
        curve: AnimationCurve = .bezier(.default)
    ) throws(LayerError) -> UInt64 {
        try requireSameContext(layer)
        let generation = generation ?? context.nextContentGeneration()
        transitions.append(TransitionRecord(
            kind: kind,
            layerId: layer.id.rawValue,
            operationId: operationID,
            generation: generation,
            duration: duration,
            curve: curve
        ))
        return generation
    }

    public mutating func clearTransition(layer: Layer) throws(LayerError) {
        try requireSameContext(layer)
        transitions.append(TransitionRecord(
            kind: .clear,
            layerId: layer.id.rawValue,
            operationId: 0,
            generation: 0,
            duration: 0,
            curve: .linear
        ))
    }

    public mutating func createLayer(_ descriptor: LayerDescriptor = LayerDescriptor()) -> Layer {
        let layer = context.makeLayer(descriptor)
        mutations.append(.created(layer.id, descriptor))
        return layer
    }

    public mutating func createLayer(id: LayerID, _ descriptor: LayerDescriptor = LayerDescriptor()) -> Layer {
        let layer = context.makeLayer(id: id, descriptor)
        mutations.append(.created(layer.id, descriptor))
        return layer
    }

    public mutating func createExisting(_ layer: Layer) throws(LayerError) {
        try requireSameContext(layer)
        mutations.append(.created(layer.id, layer.descriptor))
    }

    public mutating func insert(_ layer: Layer, into parent: Layer? = nil, at index: UInt32 = UInt32.max) throws(LayerError) {
        try requireSameContext(layer)
        if let parent {
            try requireSameContext(parent)
        }
        layer.attach(to: parent, at: index)
        mutations.append(.inserted(layer: layer.id, parent: parent?.id, index: index))
    }

    public mutating func setProperties(_ properties: LayerPropertyUpdate, for layer: Layer) throws(LayerError) {
        try requireSameContext(layer)
        layer.apply(properties)
        mutations.append(.properties(layer: layer.id, properties))
    }

    public mutating func detach(_ layer: Layer) throws(LayerError) {
        try requireSameContext(layer)
        layer.detach()
        mutations.append(.detached(layer.id))
    }

    public mutating func remove(_ layer: Layer) throws(LayerError) {
        try requireSameContext(layer)
        layer.detach()
        context.layers[layer.id] = nil
        mutations.append(.removed(layer.id))
    }

    public mutating func add(_ animation: Animation, to layer: Layer) throws(LayerError) {
        try requireSameContext(layer)
        mutations.append(.animationAdded(layer: layer.id, animation))
    }

    public mutating func removeAnimation(for keyPath: AnimationKeyPath, from layer: Layer) throws(LayerError) {
        try requireSameContext(layer)
        mutations.append(.animationRemoved(layer: layer.id, keyPath))
    }

    public mutating func setPaintCommands(
        _ commands: [PaintCommand],
        payload: [UInt8] = [],
        width: Float,
        height: Float,
        for layer: Layer
    ) throws(LayerError) {
        let content = try PaintContent.register(
            commands, payload: payload, width: width, height: height, in: context)
        try setContent(LayerContent(content), for: layer)
        withExtendedLifetime(content) {}
    }

    public mutating func setContent(_ content: LayerContent, for layer: Layer) throws(LayerError) {
        try requireSameContext(layer)
        let update = LayerPropertyUpdate(content: content)
        if content.generation != 0 {
            try addContentGenerationHold(layer: layer, generation: content.generation)
        }
        try setProperties(update, for: layer)
    }

    public mutating func commit() throws(LayerError) {
        let encoded = self.encoded()
        _ = context.nextRevision()
        try context.commitSink.commit(encoded)
        completed = true
    }

    /// Discards the pending FFI-side commit. Local Swift state is **not**
    /// rolled back — mirrors `CATransaction`, where calling `commit` /
    /// abandoning the transaction does not undo property writes already
    /// made on the layer model. Once you set `position`, it stays set.
    public mutating func abort() {
        mutations.removeAll()
        completed = true
    }

    // MARK: - Ambient transaction (CATransaction-shaped implicit grouping)

    /// Pushes a tree-mutation or property-update into whatever transaction
    /// is currently active for `context`: the topmost explicit `Transaction`
    /// if one is in scope, otherwise the per-context implicit ambient
    /// buffer.
    ///
    /// Local Swift model state (Layer.descriptor / Layer.parent / Layer.sublayers)
    /// is updated **eagerly at the call site** by the caller — this method
    /// is only responsible for journaling the mutation so the FFI layer
    /// learns about it on the next commit / flush.
    @MainActor
    @_spi(NucleusCompositor) public static func appendAmbient(_ mutation: LayerMutation, in context: Context) {
        context.transactionStack.append(mutation)
    }

    /// Flushes the per-context implicit ambient buffer through the
    /// commit sink. Idempotent — a no-op if no implicit work is pending.
    /// Consumers (compositor, tests, future standalone apps) install this
    /// as their event-model flush trigger; the ambient buffer never
    /// auto-commits on its own.
    @MainActor
    public static func flushImplicit(in context: Context) throws(LayerError) {
        let drained = context.transactionStack.drainImplicit()
        if drained.isEmpty {
            return
        }
        defer {
            LayerMutation.releaseResourceHandles(in: drained)
        }
        var t = LayerTransaction(context: context)
        t.mutations = drained
        try t.commit()
    }

    package func encoded() -> EncodedTransaction {
        var created: [(LayerID, LayerDescriptor)] = []
        var inserted: [(layer: LayerID, parent: LayerID?, index: UInt32)] = []
        var removed: [LayerID] = []
        var detached: [LayerID] = []
        var properties: [(layer: LayerID, properties: LayerPropertyUpdate)] = []
        var animationsAdded: [(layer: LayerID, animation: Animation)] = []
        var animationsRemoved: [(layer: LayerID, keyPath: AnimationKeyPath)] = []

        for mutation in mutations {
            switch mutation {
            case .created(let id, let descriptor):
                created.append((id, descriptor))
            case .inserted(let layer, let parent, let index):
                inserted.append((layer, parent, index))
            case .removed(let id):
                removed.append(id)
            case .detached(let id):
                detached.append(id)
            case .properties(let layer, let update):
                properties.append((layer, update))
            case .animationAdded(let layer, let animation):
                animationsAdded.append((layer, animation))
            case .animationRemoved(let layer, let keyPath):
                animationsRemoved.append((layer, keyPath))
            }
        }

        return EncodedTransaction(
            contextID: context.id,
            transactionID: transactionID,
            groupID: groupID,
            groupSequence: groupSequence,
            revision: context.revision,
            predictedPresentationNanoseconds: predictedPresentationNanoseconds,
            targetPresentationNanoseconds: targetPresentationNanoseconds,
            completionToken: completionToken,
            fences: fences,
            created: created,
            inserted: inserted,
            removed: removed,
            detached: detached,
            propertyUpdates: properties,
            animationsAdded: animationsAdded,
            animationsRemoved: animationsRemoved,
            transitions: transitions
        )
    }

    private func requireSameContext(_ layer: Layer) throws(LayerError) {
        guard layer.context === context else {
            throw .invalidArgument(detail: "layer belongs to another context")
        }
    }

}

// C-side wire transaction interop was deleted with the old host bridge; this
// module owns only the app-facing transaction model.

// Animation.wireValue(layerID:) is defined — see DirectBridge.swift.
