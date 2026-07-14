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

    public override init() throws(UIError) {
        self.isEnabled = true
        self.isHighlighted = false
        self.isPressed = false
        try super.init()
    }

    public func onPrimaryAction(_ handler: @escaping (Control) -> Void) throws(UIError) {
        try setAction(.primary) { [weak self] _ in
            guard let self else { return }
            handler(self)
        }
    }

    public func sendAction(_ action: ActionID, event: Event) throws(UIError) -> EventHandling {
        guard isEnabled else {
            return .notHandled
        }

        do {
            try performAction(action, event: event)
            return .handled
        } catch UIError.notImplemented {
            return .notHandled
        }
    }

    public override func handleEvent(_ event: Event) throws(UIError) -> EventHandling {
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
            return try sendAction(.primary, event: event)
        case .action:
            return try sendAction(.primary, event: event)
        }
    }
}
