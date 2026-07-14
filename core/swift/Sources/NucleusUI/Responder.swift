@MainActor
open class Responder: ~Sendable {
    package var responderActions: [ActionID: (Event) throws(UIError) -> Void]
    package weak var explicitNextResponder: Responder?

    public init() throws(UIError) {
        responderActions = [:]
        explicitNextResponder = nil
    }

    open var nextResponder: Responder? {
        get { explicitNextResponder }
        set { explicitNextResponder = newValue }
    }

    open func handleEvent(_ event: Event) throws(UIError) -> EventHandling {
        _ = event
        return .notHandled
    }

    open func tryToPerform(_ action: ActionID, event: Event) throws(UIError) -> Bool {
        guard let handler = responderActions[action] else {
            return false
        }
        try handler(event)
        return true
    }

    public func setAction(_ action: ActionID, handler: @escaping (Event) throws(UIError) -> Void) throws(UIError) {
        responderActions[action] = handler
    }

    public func clearAction(_ action: ActionID) throws(UIError) {
        responderActions.removeValue(forKey: action)
    }

    public func performAction(_ action: ActionID, event: Event) throws(UIError) {
        if try tryToPerform(action, event: event) {
            return
        }
        if let nextResponder {
            try nextResponder.performAction(action, event: event)
            return
        }
        throw .notImplemented(detail: "responder action is not registered")
    }
}

@MainActor
public enum EventHandling: Sendable, Equatable {
    case handled
    case notHandled
}

@MainActor
public enum EventDispatcher {
    public static func dispatch(_ event: Event, from root: View) throws(UIError) -> EventHandling {
        guard let target = try root.hitTest(event.location) else {
            return .notHandled
        }
        var current: Responder? = target
        while let responder = current {
            let result = try responder.handleEvent(event)
            if result == .handled {
                return .handled
            }
            current = responder.nextResponder
        }
        return .notHandled
    }
}
