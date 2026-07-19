@MainActor
open class Control: View, ~Sendable {
    public var isEnabled: Bool {
        didSet {
            if !isEnabled {
                isHighlighted = false
                isPressed = false
            }
        }
    }
    public private(set) var isHighlighted: Bool
    public private(set) var isPressed: Bool

    /// A control takes keyboard focus while it is enabled.
    ///
    /// Previously only `TextField` declared this, so no button could be focused
    /// or reached by tab — every control but one was keyboard-inert. `NSControl`
    /// has the same rule.
    open override var acceptsFirstResponder: Bool { isEnabled }

    public override init() {
        self.isEnabled = true
        self.isHighlighted = false
        self.isPressed = false
        super.init()
        // Every control is hoverable. A control that had to be asked to track
        // the pointer would be a control most callers forgot to ask.
        addTracking()
    }

    /// A disabled control is not hovered, whatever the pointer is doing — the
    /// hover state exists to signal "this responds", and a disabled one does not.
    open override func hoverStateDidChange() {
        if isHovered && !isEnabled {
            isHovered = false
            return
        }
        super.hoverStateDidChange()
    }

    public func onPrimaryAction(_ handler: @escaping (Control) -> Void) {
        setAction(.primary) { [weak self] _ in
            guard let self else { return }
            handler(self)
        }
    }

    public func sendAction(_ action: ActionID, event: Event) -> EventHandling {
        guard isEnabled else {
            return .notHandled
        }
        return performAction(action, event: event) ? .handled : .notHandled
    }

    public override func handleEvent(_ event: Event) -> EventHandling {
        guard isEnabled else {
            return .notHandled
        }

        switch event.type {
        case .pointerDown:
            // Only the primary button presses a control; a right-click should
            // reach a context menu, not fire the action.
            guard event.button == .left else { return .notHandled }
            isPressed = true
            isHighlighted = true
            return .handled

        case .pointerDragged:
            // Dragging off a pressed control un-highlights it but keeps the
            // press latched, so dragging back in re-arms it. This is the
            // AppKit/UIKit tracking contract, and it is why a press cannot be
            // cancelled just by leaving.
            guard isPressed else { return .notHandled }
            isHighlighted = contains(event.location)
            return .handled

        case .pointerExited:
            guard isPressed else { return .notHandled }
            isHighlighted = false
            return .handled

        case .pointerEntered:
            guard isPressed else { return .notHandled }
            isHighlighted = true
            return .handled

        case .pointerUp:
            guard event.button == .left, isPressed else { return .notHandled }
            let wasInside = contains(event.location)
            isPressed = false
            isHighlighted = false
            // Releasing outside cancels rather than fires. Previously the latch
            // cleared on any release wherever it landed, so dragging off a
            // button and letting go still triggered it.
            guard wasInside else { return .handled }
            return sendAction(.primary, event: event)

        case .action:
            return sendAction(.primary, event: event)

        case .pointerMoved, .scrollWheel,
             .keyDown, .keyUp, .flagsChanged,
             .touchDown, .touchMoved, .touchUp, .touchCancelled:
            return .notHandled
        }
    }

    /// Whether a view-local point lies inside this control.
    private func contains(_ point: Point) -> Bool {
        point.x >= 0 && point.y >= 0
            && point.x < bounds.size.width && point.y < bounds.size.height
    }
}
