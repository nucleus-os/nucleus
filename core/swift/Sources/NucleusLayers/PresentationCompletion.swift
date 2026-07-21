/// Terminal result for work accepted by the retained renderer.
public enum PresentationCompletionResult: Sendable, Equatable {
    case completed
    case cancelled
    case superseded
    case skippedReducedMotion
    case failed
}

/// Opaque identity joining a producer request to its renderer acknowledgement.
public struct PresentationCompletionToken: RawRepresentable, Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "presentation completion token zero is reserved")
        self.rawValue = rawValue
    }
}

/// One runtime graph's main-actor completion rendezvous, shared by its layer
/// producers and render commit sink.
///
/// Registration retains the callback until exactly one terminal result arrives.
/// Tokens are unique within this registry and never reused. Raw tokens cross
/// only the matching runtime's producer/store boundary.
@MainActor
public final class PresentationCompletionRegistry: ~Sendable {
    private var nextToken: UInt64 = 1
    private var callbacks: [
        PresentationCompletionToken: @MainActor (PresentationCompletionResult) -> Void
    ] = [:]
    private var isLive = true

    public init() {}

    public func register(
        _ callback: @escaping @MainActor (PresentationCompletionResult) -> Void
    ) -> PresentationCompletionToken {
        precondition(isLive, "cannot register completion after runtime teardown")
        let token = PresentationCompletionToken(rawValue: nextToken)
        nextToken &+= 1
        precondition(nextToken != 0, "presentation completion token space exhausted")
        callbacks[token] = callback
        return token
    }

    public func resolve(
        _ token: PresentationCompletionToken,
        result: PresentationCompletionResult
    ) {
        guard let callback = callbacks.removeValue(forKey: token) else { return }
        callback(result)
    }

    public func resolve(
        rawToken: UInt64,
        result: PresentationCompletionResult
    ) {
        guard rawToken != 0 else { return }
        resolve(PresentationCompletionToken(rawValue: rawToken), result: result)
    }

    public func discard(_ token: PresentationCompletionToken) {
        callbacks[token] = nil
    }

    /// Tear down the rendezvous without retaining producer callback state.
    /// Any later native/store acknowledgement is rejected as an unknown token.
    public func invalidate(
        result: PresentationCompletionResult = .cancelled
    ) {
        guard isLive else { return }
        isLive = false
        let pending = callbacks.values
        callbacks.removeAll(keepingCapacity: false)
        for callback in pending {
            callback(result)
        }
    }

    package var pendingCount: Int {
        callbacks.count
    }
}
