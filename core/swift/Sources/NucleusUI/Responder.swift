@MainActor
open class Responder: ~Sendable {
    package var responderActions: [ActionID: (Event) -> Void]
    package weak var explicitNextResponder: Responder?

    public init() {
        responderActions = [:]
        explicitNextResponder = nil
    }

    open var nextResponder: Responder? {
        get { explicitNextResponder }
        set { explicitNextResponder = newValue }
    }

    open func handleEvent(_ event: Event) -> EventHandling {
        _ = event
        return .notHandled
    }

    /// Invoke `action` on this responder alone. Returns whether a handler was
    /// registered. Mirrors `NSResponder.tryToPerform(_:with:)`.
    open func tryToPerform(_ action: ActionID, event: Event) -> Bool {
        guard let handler = responderActions[action] else {
            return false
        }
        handler(event)
        return true
    }

    public func setAction(_ action: ActionID, handler: @escaping (Event) -> Void) {
        responderActions[action] = handler
    }

    public func clearAction(_ action: ActionID) {
        responderActions.removeValue(forKey: action)
    }

    /// Walk the responder chain until one responder handles `action`. Returns
    /// whether any did. An unhandled action is a normal outcome, not an error —
    /// mirrors `NSApplication.sendAction(_:to:from:)`.
    @discardableResult
    public func performAction(_ action: ActionID, event: Event) -> Bool {
        var current: Responder? = self
        while let responder = current {
            if responder.tryToPerform(action, event: event) {
                return true
            }
            current = responder.nextResponder
        }
        return false
    }
}

@MainActor
public enum EventHandling: Sendable, Equatable {
    case handled
    case notHandled
}

@MainActor
public enum EventDispatcher {
    public static func dispatch(_ event: Event, from root: View) -> EventHandling {
        guard let target = root.hitTest(event.location) else {
            return .notHandled
        }
        var current: Responder? = target
        while let responder = current {
            let result = responder.handleEvent(event)
            if result == .handled {
                return .handled
            }
            current = responder.nextResponder
        }
        return .notHandled
    }
}
