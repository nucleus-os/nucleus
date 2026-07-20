import NucleusTypes
import NucleusAppHostProtocols

public struct ContextID: RawRepresentable, Hashable, Sendable, Equatable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let root = ContextID(rawValue: NucleusTypes.rootContextId)
    public static let shellOverlay = ContextID(rawValue: NucleusTypes.shellOverlayContextId)
    public static let compositor = ContextID(rawValue: 63)
}

/// Stack of mutation buffers used by ambient and explicit transactions.
/// The bottom of the stack is the implicit ambient buffer. Explicit
/// `Transaction { ... }` blocks push a fresh buffer on entry and pop it
/// on commit / abort. Writes always land on the topmost buffer.
@MainActor
package final class TransactionStack: ~Sendable {
    package var implicit: [LayerMutation] = []
    package var explicit: [[LayerMutation]] = []

    deinit {
        LayerMutation.releaseResourceHandles(in: implicit)
        for mutations in explicit {
            LayerMutation.releaseResourceHandles(in: mutations)
        }
    }

    package func append(_ mutation: LayerMutation) {
        mutation.retainResourceHandles()
        if explicit.isEmpty {
            implicit.append(mutation)
        } else {
            explicit[explicit.count - 1].append(mutation)
        }
    }

    package func pushExplicit() {
        explicit.append([])
    }

    package func popExplicit() -> [LayerMutation] {
        explicit.removeLast()
    }

    package func drainImplicit() -> [LayerMutation] {
        defer { implicit.removeAll() }
        return implicit
    }
}

@MainActor
package final class ActiveGroup: ~Sendable {
    package let id: UInt64
    private var nextSequence: UInt32

    package init(id: UInt64) {
        self.id = id
        self.nextSequence = 1
    }

    package func allocateSequence() -> UInt32 {
        let current = nextSequence
        nextSequence &+= 1
        if nextSequence == 0 {
            nextSequence = 1
        }
        return current
    }
}

@MainActor
public final class Context: ~Sendable {
    public let id: ContextID
    public var commitSink: any CommitSink
    private let releasesContextOnDeinit: Bool
    package var nextLayerOrdinal: UInt32
    package var nextContentGenerationValue: UInt64
    package var nextTransactionIDValue: UInt64
    package var revision: UInt32
    @_spi(NucleusCompositor) public var layers: [LayerID: Layer]
    package let transactionStack: TransactionStack
    package var activeGroup: ActiveGroup?

    /// `commitSink` is required — there is no implicit default. Consumers that
    /// don't link a real host should pass `InMemoryCommitSink()` (the test sink
    /// that captures transactions without forwarding to C).
    private init(
        id: ContextID,
        commitSink: any CommitSink,
        releasesContextOnDeinit: Bool
    ) throws(LayerError) {
        guard id.rawValue != 0 else {
            throw .invalidArgument(detail: "context id must be explicit")
        }
        self.id = id
        self.commitSink = commitSink
        self.releasesContextOnDeinit = releasesContextOnDeinit
        self.nextLayerOrdinal = 1
        self.nextContentGenerationValue = 1
        self.nextTransactionIDValue = 1
        self.revision = 1
        self.layers = [:]
        self.transactionStack = TransactionStack()
        self.activeGroup = nil
    }

    public convenience init(id: ContextID, commitSink: any CommitSink) throws(LayerError) {
        try self.init(id: id, commitSink: commitSink, releasesContextOnDeinit: false)
    }

    public convenience init(commitSink: any CommitSink) throws(LayerError) {
        guard let allocator = currentHost()?.contextIDAllocator else {
            throw LayerError.backendFailure(detail: "reserve context id: layers host not installed")
        }
        let contextID: UInt32
        do {
            contextID = try allocator.reserve()
        } catch let err {
            switch err {
            case .outOfMemory:
                throw LayerError.outOfMemory
            case .contextIDExhausted:
                throw LayerError.invalidHandle(detail: "reserve context id: id space exhausted")
            }
        }
        try self.init(id: ContextID(rawValue: contextID), commitSink: commitSink, releasesContextOnDeinit: true)
    }

    public convenience init(contextID: UInt32, commitSink: any CommitSink) throws(LayerError) {
        try self.init(id: ContextID(rawValue: contextID), commitSink: commitSink)
    }

    deinit {
        if releasesContextOnDeinit {
            currentLifecycleHost()?.contextIDAllocator.release(id.rawValue)
        }
    }

    public func queryDisplayLink() throws(LayerError) -> PresentReport {
        guard let displayLink = currentHost()?.displayLinkSource else {
            throw LayerError.backendFailure(detail: "display link query: layers host not installed")
        }
        do {
            let report = try displayLink.query(contextID: id.rawValue)
            return PresentReport(report)
        } catch let err {
            switch err {
            case .invalidArgument:
                throw LayerError.invalidArgument(detail: "display link query: context id is zero")
            }
        }
    }

    public func makeLayer(_ descriptor: LayerDescriptor = LayerDescriptor()) -> Layer {
        let layer = Layer(context: self, id: allocateLayerID(), descriptor: descriptor)
        layers[layer.id] = layer
        return layer
    }

    package func nextTransactionID() -> UInt64 {
        let value = nextTransactionIDValue
        nextTransactionIDValue &+= 1
        precondition(nextTransactionIDValue != 0, "layer transaction id space exhausted")
        return value
    }

    public func makeLayer(id: LayerID, _ descriptor: LayerDescriptor = LayerDescriptor()) -> Layer {
        precondition(
            layers[id] == nil,
            "duplicate layer identity \(id.rawValue) in context \(self.id.rawValue)")
        precondition(
            UInt32(truncatingIfNeeded: id.rawValue >> 32) == self.id.rawValue,
            "explicit layer identity belongs to another context")
        let layer = Layer(context: self, id: id, descriptor: descriptor)
        layers[layer.id] = layer
        advanceLayerOrdinal(past: id)
        return layer
    }

    public func importExistingLayer(id: LayerID, _ descriptor: LayerDescriptor = LayerDescriptor()) -> Layer {
        precondition(
            UInt32(truncatingIfNeeded: id.rawValue >> 32) == self.id.rawValue,
            "imported layer identity belongs to another context")
        if let layer = layers[id] {
            return layer
        }
        let layer = Layer(context: self, id: id, descriptor: descriptor)
        layers[layer.id] = layer
        advanceLayerOrdinal(past: id)
        return layer
    }

    public func modelState(for id: LayerID) -> LayerDescriptor? {
        layers[id]?.descriptor
    }

    public func transaction(_ body: (inout LayerTransaction) throws -> Void) throws {
        var transaction = LayerTransaction(context: self)
        try body(&transaction)
        try transaction.commit()
    }

    package func allocateLayerID() -> LayerID {
        let ordinal = nextLayerOrdinal
        nextLayerOrdinal &+= 1
        if nextLayerOrdinal == 0 {
            nextLayerOrdinal = 1
        }
        return LayerID(rawValue: (UInt64(id.rawValue) << 32) | UInt64(ordinal))
    }

    private func advanceLayerOrdinal(past id: LayerID) {
        let contextBits = UInt32(truncatingIfNeeded: id.rawValue >> 32)
        guard contextBits == self.id.rawValue else {
            return
        }
        let localID = UInt32(truncatingIfNeeded: id.rawValue)
        if localID >= nextLayerOrdinal {
            nextLayerOrdinal = localID &+ 1
            if nextLayerOrdinal == 0 {
                nextLayerOrdinal = 1
            }
        }
    }

    package func nextRevision() -> UInt32 {
        let current = revision
        revision &+= 1
        if revision == 0 {
            revision = 1
        }
        return current
    }

    package func nextContentGeneration() -> UInt64 {
        let current = nextContentGenerationValue
        nextContentGenerationValue &+= 1
        if nextContentGenerationValue == 0 {
            nextContentGenerationValue = 1
        }
        return current
    }

}
