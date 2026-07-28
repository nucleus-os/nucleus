public import NucleusUI

@MainActor
private final class TaskbarWindowButton: Control {
    let windowID: UInt64
    private let label: Label
    private var snapshot: ShellWindowSnapshot

    init(window: ShellWindowSnapshot) {
        windowID = window.id
        self.snapshot = window
        label = Label(window.displayTitle)
        super.init()
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        setBody { label }
        cornerRadius = 5
        update(window)
    }

    func update(_ window: ShellWindowSnapshot) {
        snapshot = window
        label.text = window.displayTitle
        isSelected = window.isActive
        label.textColor = resolve(snapshot.isMinimized
            ? .role(.onSurfaceVariant)
            : .role(.onSurface))
        accessibilityLabel = window.displayTitle
        accessibilityValue = window.isMinimized ? "Minimized" : nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func viewDidChangeEffectiveAppearance() {
        label.textColor = resolve(snapshot.isMinimized
            ? .role(.onSurfaceVariant)
            : .role(.onSurface))
        super.viewDidChangeEffectiveAppearance()
    }

    override var intrinsicContentSize: Size {
        let proposed = label.intrinsicContentSize
        return Size(
            width: min(180, max(64, proposed.width + 16)),
            height: 22)
    }

    override func measure(_ constraints: LayoutConstraints) -> Size {
        constraints.constrain(intrinsicContentSize)
    }

    override func layout() {
        label.centerVertically(in: Rect(
            x: 8, y: 0,
            width: max(0, bounds.size.width - 16),
            height: bounds.size.height))
    }

    override func draw(in context: GraphicsContext) {
        var background = Path()
        background.addRoundedRect(bounds, radius: 5)
        let color: ColorSpec
        if isSelected {
            color = .role(.primary)
        } else if isPressed || isHovered {
            color = .role(.hover)
        } else {
            color = .role(.surfaceVariant)
        }
        context.fillColor = resolve(color)
        context.fill(background)
    }
}

/// Native taskbar projection. Reconciliation is keyed by the stable protocol
/// handle so title/state changes retain the control, its hover state, and its
/// accessibility identity.
@MainActor
public final class TaskbarWidget: BarWidget {
    public var onWindowAction:
        ((UInt64, ShellWindowAction) -> Void)?

    public private(set) var windows: [ShellWindowSnapshot] = []

    private let row: StackView
    private var buttonsByID: [UInt64: TaskbarWindowButton] = [:]

    public override init() {
        row = StackView(axis: .horizontal, spacing: 6, alignment: .center)
        super.init()
        showsCapsule = false
        accessibilityRole = .group
        accessibilityLabel = "Open windows"
        setBody { row }
    }

    public func update(windows: [ShellWindowSnapshot]) {
        guard windows != self.windows else { return }
        self.windows = windows

        let liveIDs = Set(windows.map(\.id))
        for id in Array(buttonsByID.keys) where !liveIDs.contains(id) {
            buttonsByID[id] = nil
        }

        let buttons = windows.map { window -> TaskbarWindowButton in
            let button: TaskbarWindowButton
            if let existing = buttonsByID[window.id] {
                button = existing
                button.update(window)
            } else {
                button = TaskbarWindowButton(window: window)
                button.onPrimaryAction { [weak self, weak button] _ in
                    guard let button else { return }
                    self?.perform(.activate, forWindow: button.windowID)
                }
                buttonsByID[window.id] = button
            }
            return button
        }
        row.setArrangedBody { buttons }
        accessibilityChildren = buttons
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    public func perform(
        _ action: ShellWindowAction,
        forWindow id: UInt64
    ) {
        guard windows.contains(where: { $0.id == id }) else { return }
        onWindowAction?(id, action)
    }

    public override var intrinsicContentSize: Size {
        row.measure(.unconstrained)
    }

    public override func measure(_ constraints: LayoutConstraints) -> Size {
        row.measure(constraints)
    }

    public override func layout() {
        row.arrange(in: bounds)
    }
}
