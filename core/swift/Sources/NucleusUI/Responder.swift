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
        set { setExplicitNextResponder(newValue) }
    }

    package func setExplicitNextResponder(_ responder: Responder?) {
        precondition(responder !== self, "a responder cannot follow itself")
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(self)]
        var current = responder
        while let node = current {
            let id = ObjectIdentifier(node)
            precondition(
                visited.insert(id).inserted,
                "nextResponder assignment would create a cycle")
            current = node.nextResponder
        }
        explicitNextResponder = responder
    }

    open func handleEvent(_ event: Event) -> EventHandling {
        _ = event
        return .notHandled
    }

    // MARK: - First responder

    /// Whether this responder will accept keyboard focus. Corresponds to
    /// `NSResponder.acceptsFirstResponder`; `false` by default, so a plain view
    /// is not focusable until it opts in.
    open var acceptsFirstResponder: Bool { false }

    /// Called when this responder is about to become first responder. Return
    /// `false` to refuse. Corresponds to `NSResponder.becomeFirstResponder()`.
    @discardableResult
    open func becomeFirstResponder() -> Bool { acceptsFirstResponder }

    /// Called when this responder is about to lose first-responder status.
    /// Return `false` to refuse to give it up.
    @discardableResult
    open func resignFirstResponder() -> Bool { true }

    /// Deliver `event` to this responder, then up the chain until one handles
    /// it. The routing counterpart to `performAction`: that walks the chain for
    /// a *semantic action*, this walks it for a *raw event*.
    @discardableResult
    public func deliverEvent(_ event: Event) -> EventHandling {
        deliverEventRoute(event).handling
    }

    package func deliverEventRoute(
        _ event: Event
    ) -> (handling: EventHandling, responder: Responder?) {
        var current: Responder? = self
        var visited: Set<ObjectIdentifier> = []
        while let responder = current {
            guard visited.insert(ObjectIdentifier(responder)).inserted else {
                return (.notHandled, nil)
            }
            let handling = responder.handleEvent(event)
            if handling != .notHandled { return (handling, responder) }
            current = responder.nextResponder
        }
        return (.notHandled, nil)
    }

    /// Invoke `action` on this responder alone. Returns whether a handler was
    /// registered. Corresponds to `NSResponder.tryToPerform(_:with:)`.
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
    /// corresponds to `NSApplication.sendAction(_:to:from:)`.
    @discardableResult
    public func performAction(_ action: ActionID, event: Event) -> Bool {
        var current: Responder? = self
        var visited: Set<ObjectIdentifier> = []
        while let responder = current {
            guard visited.insert(ObjectIdentifier(responder)).inserted else {
                return false
            }
            if responder.tryToPerform(action, event: event) {
                return true
            }
            current = responder.nextResponder
        }
        return false
    }
}

public enum EventHandling: Sendable, Equatable {
    case handled
    /// Handle the event and explicitly request sequence capture.
    case capture
    case notHandled
}
