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

/// Main-actor completion rendezvous shared by layer producers and the installed
/// render commit sink.
///
/// Registration retains the callback until exactly one terminal result arrives.
/// Tokens are process-unique and never reused.
@MainActor
public enum PresentationCompletionCenter {
    private static var nextToken: UInt64 = 1
    private static var callbacks: [
        PresentationCompletionToken: @MainActor (PresentationCompletionResult) -> Void
    ] = [:]

    public static func register(
        _ callback: @escaping @MainActor (PresentationCompletionResult) -> Void
    ) -> PresentationCompletionToken {
        let token = PresentationCompletionToken(rawValue: nextToken)
        nextToken &+= 1
        precondition(nextToken != 0, "presentation completion token space exhausted")
        callbacks[token] = callback
        return token
    }

    public static func resolve(
        _ token: PresentationCompletionToken,
        result: PresentationCompletionResult
    ) {
        guard let callback = callbacks.removeValue(forKey: token) else { return }
        callback(result)
    }

    public static func resolve(
        rawToken: UInt64,
        result: PresentationCompletionResult
    ) {
        guard rawToken != 0 else { return }
        resolve(PresentationCompletionToken(rawValue: rawToken), result: result)
    }

    public static func discard(_ token: PresentationCompletionToken) {
        callbacks[token] = nil
    }

    package static var pendingCount: Int {
        callbacks.count
    }
}
