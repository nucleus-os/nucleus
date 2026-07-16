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

    public override init() {
        self.isEnabled = true
        self.isHighlighted = false
        self.isPressed = false
        super.init()
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
            isPressed = true
            isHighlighted = true
            return .handled
        case .pointerUp:
            isPressed = false
            isHighlighted = false
            return sendAction(.primary, event: event)
        case .action:
            return sendAction(.primary, event: event)
        }
    }
}
