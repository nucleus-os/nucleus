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

    // MARK: - First responder

    /// Whether this responder will accept keyboard focus. Mirrors
    /// `NSResponder.acceptsFirstResponder`; `false` by default, so a plain view
    /// is not focusable until it opts in.
    open var acceptsFirstResponder: Bool { false }

    /// Called when this responder is about to become first responder. Return
    /// `false` to refuse. Mirrors `NSResponder.becomeFirstResponder()`.
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
        var current: Responder? = self
        while let responder = current {
            if responder.handleEvent(event) == .handled { return .handled }
            current = responder.nextResponder
        }
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
