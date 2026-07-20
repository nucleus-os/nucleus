/// A binary switch control.
@MainActor
open class Toggle: Control, ~Sendable {
    public var isOn: Bool {
        get { isSelected }
        set {
            guard newValue != isSelected else { return }
            isSelected = newValue
            accessibilityValue = newValue ? "On" : "Off"
            onValueChange?(newValue)
        }
    }

    private var onValueChange: ((Bool) -> Void)?

    public override init() {
        super.init()
        accessibilityRole = .switchControl
        accessibilityValue = "Off"
    }

    public convenience init(isOn: Bool) {
        self.init()
        self.isOn = isOn
    }

    public func onChange(_ handler: @escaping (Bool) -> Void) {
        onValueChange = handler
    }

    open override func performPrimaryAction(
        event: Event
    ) -> EventHandling {
        isOn.toggle()
        _ = super.performPrimaryAction(event: event)
        return .handled
    }

    open override var intrinsicContentSize: Size {
        Size(width: 38, height: 22)
    }

    open override func draw(in context: GraphicsContext) {
        let track = Rect(origin: .zero, size: bounds.size)
        var path = Path()
        path.addRoundedRect(track, radius: bounds.size.height / 2)
        context.fillColor = resolve(isOn ? .role(.primary) : .role(.surfaceVariant))
        context.fill(path)

        let inset = 3.0
        let diameter = max(0, bounds.size.height - inset * 2)
        let x = isOn
            ? max(inset, bounds.size.width - inset - diameter)
            : inset
        var thumb = Path()
        thumb.addEllipse(in: Rect(
            x: x,
            y: inset,
            width: diameter,
            height: diameter))
        context.fillColor = resolve(isOn ? .role(.onPrimary) : .role(.onSurfaceVariant))
        context.fill(thumb)
    }
}

/// A binary control with checkbox chrome.
@MainActor
public final class Checkbox: Toggle, ~Sendable {
    public override init() {
        super.init()
        accessibilityRole = .checkBox
    }

    public override var intrinsicContentSize: Size {
        Size(width: 20, height: 20)
    }

    public override func draw(in context: GraphicsContext) {
        let rect = Rect(
            x: 1,
            y: 1,
            width: max(0, bounds.size.width - 2),
            height: max(0, bounds.size.height - 2))
        var box = Path()
        box.addRoundedRect(rect, radius: 4)
        context.fillColor = resolve(isOn ? .role(.primary) : .role(.surfaceVariant))
        context.fill(box)

        guard isOn else { return }
        var check = Path()
        check.move(to: Point(
            x: bounds.size.width * 0.24,
            y: bounds.size.height * 0.52))
        check.addLine(to: Point(
            x: bounds.size.width * 0.43,
            y: bounds.size.height * 0.70))
        check.addLine(to: Point(
            x: bounds.size.width * 0.78,
            y: bounds.size.height * 0.30))
        context.strokeColor = resolve(.role(.onPrimary))
        context.lineWidth = 2
        context.lineCap = .round
        context.lineJoin = .round
        context.stroke(check)
    }
}
