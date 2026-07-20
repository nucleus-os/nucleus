public struct ControlState: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let enabled = ControlState(rawValue: 1 << 0)
    public static let hovered = ControlState(rawValue: 1 << 1)
    public static let highlighted = ControlState(rawValue: 1 << 2)
    public static let pressed = ControlState(rawValue: 1 << 3)
    public static let focused = ControlState(rawValue: 1 << 4)
    public static let selected = ControlState(rawValue: 1 << 5)
}

@MainActor
open class Control: View, ~Sendable {
    private var storedIsEnabled = true
    private var storedIsHighlighted = false
    private var storedIsPressed = false
    private var storedIsSelected = false
    private var keyboardActivationKey: KeyCode?

    public var isEnabled: Bool {
        get { storedIsEnabled }
        set {
            guard newValue != storedIsEnabled else { return }
            storedIsEnabled = newValue
            if !newValue {
                storedIsHighlighted = false
                storedIsPressed = false
                keyboardActivationKey = nil
                window?.windowScene?.cancelInputSequences(capturedBy: self)
            }
            controlStateDidChange()
        }
    }

    public private(set) var isHighlighted: Bool {
        get { storedIsHighlighted }
        set {
            guard newValue != storedIsHighlighted else { return }
            storedIsHighlighted = newValue
            controlStateDidChange()
        }
    }

    public private(set) var isPressed: Bool {
        get { storedIsPressed }
        set {
            guard newValue != storedIsPressed else { return }
            storedIsPressed = newValue
            controlStateDidChange()
        }
    }

    public var isSelected: Bool {
        get { storedIsSelected }
        set {
            guard newValue != storedIsSelected else { return }
            storedIsSelected = newValue
            controlStateDidChange()
        }
    }

    /// Optional shared state-to-style seam for custom controls.
    public var controlStyleProvider: ((ControlState) -> ViewStyle)? {
        didSet { controlStateDidChange() }
    }

    public var controlState: ControlState {
        var state: ControlState = []
        if isEnabled { state.insert(.enabled) }
        if isHovered { state.insert(.hovered) }
        if isHighlighted { state.insert(.highlighted) }
        if isPressed { state.insert(.pressed) }
        if isFocused { state.insert(.focused) }
        if isSelected { state.insert(.selected) }
        return state
    }

    open override var acceptsFirstResponder: Bool { isEnabled }

    open override var environmentDependencies: UIEnvironmentChanges {
        super.environmentDependencies
    }

    /// Generic controls activate with Space. Buttons add Return.
    open var keyboardActivationKeys: Set<KeyCode> { [.space] }

    public override init() {
        super.init()
        addTracking()
        isAccessibilityElement = true
        synchronizeAccessibilityState()
    }

    open func controlStateDidChange() {
        if let controlStyleProvider {
            style = controlStyleProvider(controlState)
        }
        synchronizeAccessibilityState()
        setNeedsDisplay()
    }

    private func synchronizeAccessibilityState() {
        var traits = accessibilityTraits
        traits.remove([.disabled, .selected])
        if !isEnabled { traits.insert(.disabled) }
        if isSelected { traits.insert(.selected) }
        accessibilityTraits = traits
    }

    open override func focusStateDidChange() {
        super.focusStateDidChange()
        controlStateDidChange()
    }

    open override func hoverStateDidChange() {
        if isHovered && !isEnabled {
            isHovered = false
            return
        }
        controlStateDidChange()
    }

    public func onPrimaryAction(_ handler: @escaping (Control) -> Void) {
        setAction(.primary) { [weak self] _ in
            guard let self else { return }
            handler(self)
        }
    }

    public func sendAction(_ action: ActionID, event: Event) -> EventHandling {
        guard isEnabled else { return .notHandled }
        return performAction(action, event: event) ? .handled : .notHandled
    }

    open func performPrimaryAction(event: Event) -> EventHandling {
        sendAction(.primary, event: event)
    }

    public override func handleEvent(_ event: Event) -> EventHandling {
        guard isEnabled else { return .notHandled }

        switch event.type {
        case .pointerDown:
            guard event.button == .left else { return .notHandled }
            setTrackingState(pressed: true, highlighted: true)
            _ = window?.makeFirstResponder(self)
            return .handled

        case .touchDown:
            setTrackingState(pressed: true, highlighted: true)
            return .handled

        case .pointerDragged, .touchMoved:
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

        case .pointerUp, .touchUp:
            if event.type == .pointerUp && event.button != .left {
                return .notHandled
            }
            guard isPressed else { return .notHandled }
            let activates = contains(event.location)
            setTrackingState(pressed: false, highlighted: false)
            return activates ? performPrimaryAction(event: event) : .handled

        case .pointerCancelled, .touchCancelled:
            guard isPressed else { return .notHandled }
            setTrackingState(pressed: false, highlighted: false)
            return .handled

        case .keyDown:
            guard isFocused,
                  keyboardActivationKeys.contains(event.keyCode)
            else { return .notHandled }
            if keyboardActivationKey == nil {
                keyboardActivationKey = event.keyCode
                setTrackingState(pressed: true, highlighted: true)
            }
            return .handled

        case .keyUp:
            guard keyboardActivationKey == event.keyCode else {
                return .notHandled
            }
            keyboardActivationKey = nil
            setTrackingState(pressed: false, highlighted: false)
            return performPrimaryAction(event: event)

        case .action:
            return performPrimaryAction(event: event)

        case .pointerMoved, .scrollWheel, .flagsChanged:
            return .notHandled
        }
    }

    private func setTrackingState(pressed: Bool, highlighted: Bool) {
        guard pressed != storedIsPressed
            || highlighted != storedIsHighlighted
        else { return }
        storedIsPressed = pressed
        storedIsHighlighted = highlighted
        controlStateDidChange()
    }

    package func contains(_ point: Point) -> Bool {
        point.x >= 0 && point.y >= 0
            && point.x < bounds.size.width && point.y < bounds.size.height
    }
}
