package import NucleusLayers
internal import struct NucleusTypes.Rect

/// Immutable mutation policy for one scoped semantic transaction.
public struct TransactionConfiguration: Sendable, Equatable {
    public let actionPolicy: ActionPolicy

    public init(actionPolicy: ActionPolicy = .none) {
        self.actionPolicy = actionPolicy
    }

    public static let immediate = TransactionConfiguration(actionPolicy: .none)
    public static let animated = TransactionConfiguration(actionPolicy: .default)
}

public enum TransactionOutcome: Sendable, Equatable {
    case completed
    case cancelled
    case superseded
    case skippedReducedMotion
    case failed
}

/// Completion for one scoped semantic transaction.
///
/// A successful mutation scope queues this handle onto the owning `UIContext`.
/// The scene publisher joins it to the next visual transaction and resolves it
/// only after that transaction is presented.
@MainActor
public final class TransactionCompletionHandle: ~Sendable {
    public private(set) var outcome: TransactionOutcome?
    public var isFinished: Bool { outcome != nil }
    private var callbacks: [
        @MainActor (TransactionOutcome) -> Void
    ] = []

    package init(
        completion: (@MainActor (TransactionOutcome) -> Void)?
    ) {
        if let completion {
            callbacks.append(completion)
        }
    }

    @discardableResult
    public func onCompletion(
        _ callback: @escaping @MainActor (TransactionOutcome) -> Void
    ) -> Self {
        if let outcome {
            callback(outcome)
        } else {
            callbacks.append(callback)
        }
        return self
    }

    package func resolve(_ outcome: TransactionOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let callbacks = callbacks
        self.callbacks.removeAll(keepingCapacity: false)
        for callback in callbacks {
            callback(outcome)
        }
    }
}

/// Internal single-consumption scope. Its destructor is the abort path, so a
/// thrown body can never leave a policy frame installed in `UIContext`.
@MainActor
private final class SemanticTransactionScopeState: ~Sendable {
    private let uiContext: UIContext
    private var isOpen = true

    init(
        uiContext: UIContext,
        configuration: TransactionConfiguration
    ) {
        self.uiContext = uiContext
        uiContext.pushActionPolicy(configuration.actionPolicy)
    }

    func finish() {
        guard isOpen else { return }
        isOpen = false
        uiContext.popActionPolicy()
    }

    isolated deinit {
        if isOpen {
            uiContext.popActionPolicy()
        }
    }
}

@MainActor
private struct SemanticTransactionScope: ~Copyable, ~Sendable {
    private let state: SemanticTransactionScopeState

    init(
        uiContext: UIContext,
        configuration: TransactionConfiguration
    ) {
        state = SemanticTransactionScopeState(
            uiContext: uiContext,
            configuration: configuration
        )
    }

    func finish() {
        state.finish()
    }
}

/// Scoped semantic transaction API.
///
/// View state remains eager. The immutable action policy is captured by every
/// mutation authored in `body`; nested scopes deterministically override only
/// mutations in the inner body and then restore the outer policy.
@MainActor
public enum Transaction {
    @discardableResult
    public static func run(
        in view: View,
        configuration: TransactionConfiguration = .immediate,
        completion: (@MainActor (TransactionOutcome) -> Void)? = nil,
        _ body: () throws -> Void
    ) throws(UIError) -> TransactionCompletionHandle {
        try run(
            in: view.uiContext,
            configuration: configuration,
            completion: completion,
            body
        )
    }

    @discardableResult
    public static func animate(
        in view: View,
        completion: (@MainActor (TransactionOutcome) -> Void)? = nil,
        _ body: () throws -> Void
    ) throws(UIError) -> TransactionCompletionHandle {
        try run(
            in: view,
            configuration: .animated,
            completion: completion,
            body
        )
    }

    @discardableResult
    package static func run(
        in uiContext: UIContext,
        configuration: TransactionConfiguration = .immediate,
        completion: (@MainActor (TransactionOutcome) -> Void)? = nil,
        _ body: () throws -> Void
    ) throws(UIError) -> TransactionCompletionHandle {
        let scope = SemanticTransactionScope(
            uiContext: uiContext,
            configuration: configuration
        )
        do {
            try body()
            scope.finish()
            let handle = TransactionCompletionHandle(completion: completion)
            uiContext.enqueueTransactionCompletion(handle)
            return handle
        } catch let error as UIError {
            scope.finish()
            throw error
        } catch {
            scope.finish()
            throw .unknown(code: 1, detail: String(describing: error))
        }
    }

    /// Nonthrowing package path for retained mechanisms whose update closure
    /// cannot fail. Keeping this separate avoids converting an impossible
    /// error into a force-try at every lifecycle-bound caller.
    package static func runNonThrowing(
        in uiContext: UIContext,
        configuration: TransactionConfiguration,
        requestsPresentationCompletion: Bool,
        _ body: () -> Void
    ) -> TransactionCompletionHandle? {
        let scope = SemanticTransactionScope(
            uiContext: uiContext,
            configuration: configuration)
        body()
        scope.finish()
        guard requestsPresentationCompletion else { return nil }
        let handle = TransactionCompletionHandle(completion: nil)
        uiContext.enqueueTransactionCompletion(handle)
        return handle
    }
}

extension ViewProperties {
    package func layerUpdate() -> LayerPropertyUpdate {
        let geometry = frame.map {
            GeometryRect(
                x: $0.origin.x,
                y: $0.origin.y,
                width: $0.size.width,
                height: $0.size.height
            )
        }
        var update = geometry.map {
            LayerPropertyUpdate.decomposedFrame($0)
        } ?? LayerPropertyUpdate()
        update.isHidden = isHidden
        update.backdropMaterial = backdropMaterial
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

package extension TransactionOutcome {
    init(_ result: PresentationCompletionResult) {
        switch result {
        case .completed:
            self = .completed
        case .cancelled:
            self = .cancelled
        case .superseded:
            self = .superseded
        case .skippedReducedMotion:
            self = .skippedReducedMotion
        case .failed:
            self = .failed
        }
    }
}
