import NucleusLayers

/// CATransaction-shaped animation grouping context. Property writes and
/// tree mutations on `View` / `Window` apply eagerly; an explicit
/// `Transaction { ... }` block exists to group those eager writes into a
/// single FFI commit and to override the action policy that resolves
/// implicit animations on writes inside the block.
///
/// Aborting a transaction discards the pending FFI commit. It does **not**
/// roll back model state — once you set `view.frame = X`, it stays set.
/// Mirrors `CATransaction`'s commit/abort semantics.
///
/// Nested explicit transactions are not supported in this revision.
@MainActor
public struct Transaction: ~Copyable, ~Sendable {
    package let context: Context
    package var actionPolicy: ActionPolicy
    package var completed: Bool

    public init() {
        self.init(context: Application.currentContext)
    }

    package init(context: Context, actionPolicy: ActionPolicy = .none) {
        self.context = context
        self.actionPolicy = actionPolicy
        self.completed = false
        // Push a fresh explicit buffer onto the context's transaction
        // stack. From now until commit() / abort(), all eager
        // ambient-routed writes (View.setFrame, view.addSubview, etc.)
        // land in this buffer instead of the per-context implicit
        // ambient.
        context.transactionStack.pushExplicit()
    }

    /// Sets the action policy resolved on writes that happen inside this
    /// transaction. Writes that landed before this call are not retroactively
    /// rewritten; subsequent writes pick up the new policy at commit.
    public mutating func setActionPolicy(_ policy: ActionPolicy) {
        actionPolicy = policy
    }

    public mutating func commit() throws(UIError) {
        guard !completed else { return }
        completed = true
        let mutations = context.transactionStack.popExplicit()
        defer {
            LayerMutation.releaseResourceHandles(in: mutations)
        }
        if mutations.isEmpty {
            return
        }
        var t = LayerTransaction(context: context)
        t.mutations = applyActionPolicy(to: mutations)
        do {
            try t.commit()
        } catch let error {
            throw UIError(error)
        }
    }

    /// Discards the pending FFI commit. Local Swift / layer model state
    /// is NOT rolled back — matches `CATransaction`.
    public mutating func abort() {
        if !completed {
            let mutations = context.transactionStack.popExplicit()
            LayerMutation.releaseResourceHandles(in: mutations)
            completed = true
        }
    }

    public static func animate(
        actionPolicy: ActionPolicy = .default,
        _ body: () throws -> Void
    ) throws(UIError) {
        try run(actionPolicy: actionPolicy, body)
    }

    public static func run(
        actionPolicy: ActionPolicy = .default,
        _ body: () throws -> Void
    ) throws(UIError) {
        try run(in: Application.currentContext, actionPolicy: actionPolicy, body)
    }

    package static func run(
        in context: Context,
        actionPolicy: ActionPolicy = .default,
        _ body: () throws -> Void
    ) throws(UIError) {
        var transaction = Transaction(context: context)
        transaction.setActionPolicy(actionPolicy)
        do {
            try body()
            try transaction.commit()
        } catch let error as UIError {
            transaction.abort()
            throw error
        } catch {
            transaction.abort()
            throw .unknown(code: 1, detail: String(describing: error))
        }
    }

    @discardableResult
    package static func run(
        in context: Context,
        duration: Double,
        nowNs: UInt64,
        actionPolicy: ActionPolicy = .default,
        _ body: () throws -> Void,
        completion: (() -> Void)?
    ) throws(UIError) -> TransactionCompletion? {
        try run(in: context, actionPolicy: actionPolicy, body)
        guard let completion else {
            return nil
        }
        return TransactionCompletion(
            deadlineNs: nowNs + UInt64(max(0, duration) * 1_000_000_000),
            completion: completion
        )
    }

    private func applyActionPolicy(to mutations: [LayerMutation]) -> [LayerMutation] {
        guard actionPolicy != .none else { return mutations }
        return mutations.map { mutation in
            switch mutation {
            case .properties(let layer, var update):
                update.actionPolicy = actionPolicy.layersPolicy
                return .properties(layer: layer, update)
            default:
                return mutation
            }
        }
    }
}

@MainActor
public final class TransactionCompletion: ~Sendable {
    public let deadlineNs: UInt64
    private var completion: (() -> Void)?

    package init(deadlineNs: UInt64, completion: @escaping () -> Void) {
        self.deadlineNs = deadlineNs
        self.completion = completion
    }

    @discardableResult
    public func fireIfDue(nowNs: UInt64) -> Bool {
        guard nowNs >= deadlineNs, let completion else {
            return false
        }
        self.completion = nil
        completion()
        return true
    }
}

extension ViewProperties {
    package func layerUpdate() -> LayerPropertyUpdate {
        let geometry = frame.map { GeometryRect(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height) }
        var update = geometry.map { LayerPropertyUpdate.decomposedFrame($0) } ?? LayerPropertyUpdate()
        let rest = LayerPropertyUpdate(
            isHidden: isHidden,
            opacity: nil,
            backdropMaterial: backdropMaterial,
            actionPolicy: .none
        )
        update.isHidden = rest.isHidden
        update.backdropMaterial = rest.backdropMaterial
        return update
    }
}

extension UIError {
    package init(_ error: LayerError) {
        switch error {
        case .invalidHandle(let detail):
            self = .invalidHandle(detail: detail)
        case .outOfMemory:
            self = .outOfMemory
        case .invalidArgument(let detail):
            self = .invalidArgument(detail: detail)
        case .backendFailure(let detail):
            self = .backendFailure(detail: detail)
        case .notImplemented(let detail):
            self = .notImplemented(detail: detail)
        case .unknown(let code, let detail):
            self = .unknown(code: code, detail: detail)
        }
    }
}
