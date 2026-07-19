import NucleusUI

/// What a battery indicator displays.
///
/// A product-tier value type, deliberately not UPower's vocabulary. The widget
/// renders this and nothing else — it never sees a bus, a service, or a device
/// path — so the same widget serves any power source and can be tested by
/// assignment.
public struct BatteryLevel: Sendable, Equatable {
    /// 0...1. Clamped on construction, because a widget that draws a fill wider
    /// than its body because a service reported 101% is a bug at the wrong end.
    public var fraction: Double
    public var isCharging: Bool
    /// Whether a battery exists at all. A desktop has none, which is not zero
    /// percent — the widget hides rather than showing an empty battery.
    public var isPresent: Bool
    public var secondsRemaining: Int64?

    public init(
        fraction: Double,
        isCharging: Bool = false,
        isPresent: Bool = true,
        secondsRemaining: Int64? = nil
    ) {
        self.fraction = min(max(0, fraction), 1)
        self.isCharging = isCharging
        self.isPresent = isPresent
        self.secondsRemaining = secondsRemaining
    }

    public static let absent = BatteryLevel(fraction: 0, isPresent: false)

    /// Rounded percentage for display.
    public var percentageText: String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

/// A battery indicator: a drawn cell that fills with charge, plus a percentage.
///
/// The first native bar widget. Its shape is the point of the exercise — a
/// service maps the system's state onto `BatteryLevel` and calls `update`, and
/// everything after that is property assignment on retained views. There is no
/// tree, no diff, and no re-description.
@MainActor
public final class BatteryWidget: View {
    public private(set) var level: BatteryLevel = .absent

    public var showsPercentage: Bool = true {
        didSet { if showsPercentage != oldValue { applyLevel() } }
    }

    /// Below this fraction the cell draws in `warningColor`.
    public var warningThreshold: Double = 0.2 {
        didSet { if warningThreshold != oldValue { setNeedsDisplay() } }
    }

    public var tintColor: Color = Color(0.90, 0.93, 0.97, 1) {
        didSet { if tintColor != oldValue { refreshColors() } }
    }
    public var warningColor: Color = Color(0.95, 0.45, 0.40, 1) {
        didSet { if warningColor != oldValue { setNeedsDisplay() } }
    }
    public var chargingColor: Color = Color(0.45, 0.85, 0.55, 1) {
        didSet { if chargingColor != oldValue { setNeedsDisplay() } }
    }

    public let percentageLabel: Label

    private static let cellWidth: Double = 22
    private static let cellHeight: Double = 12
    private static let terminalWidth: Double = 2
    private static let terminalHeight: Double = 5
    private static let labelSpacing: Double = 5

    public override init() {
        percentageLabel = Label("")
        super.init()
        percentageLabel.font = .systemFont(ofSize: 11)
        percentageLabel.textColor = tintColor
        accessibilityRole = .staticText
        setBody { percentageLabel }
        // The tooltip is a provider rather than a string: it must describe the
        // reading at the moment the pointer rests, not the one that happened to
        // be current when the widget was built.
        addTracking(
            cursor: .pointingHand,
            toolTipProvider: { [weak self] in self?.accessibilityDescription })
        applyLevel()
    }

    /// Take a new reading. The whole update path: assign, invalidate, done.
    public func update(_ level: BatteryLevel) {
        guard level != self.level else { return }
        self.level = level
        applyLevel()
    }

    private func applyLevel() {
        isHidden = !level.isPresent
        percentageLabel.isHidden = !showsPercentage
        percentageLabel.text = level.isPresent ? level.percentageText : ""
        accessibilityLabel = accessibilityDescription
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func refreshColors() {
        percentageLabel.textColor = tintColor
        setNeedsDisplay()
    }

    /// Spoken description, and the tooltip text. A drawn cell says nothing to an
    /// assistive technology on its own, and "73%" alone does not say 73% of
    /// what — which is exactly what a tooltip has to answer too.
    var accessibilityDescription: String {
        guard level.isPresent else { return "No battery" }
        if level.isCharging { return "Battery \(level.percentageText), charging" }
        guard let seconds = level.secondsRemaining else {
            return "Battery \(level.percentageText)"
        }
        return "Battery \(level.percentageText), \(BatteryWidget.durationText(seconds)) remaining"
    }

    /// Coarse duration, because a battery estimate is coarse. Reporting
    /// "2 hours 47 minutes" from a figure that moves by ten minutes when a fan
    /// spins up is false precision.
    static func durationText(_ seconds: Int64) -> String {
        let minutes = max(0, seconds) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    // MARK: - Layout

    public override var intrinsicContentSize: Size {
        let cell = BatteryWidget.cellWidth + BatteryWidget.terminalWidth
        guard showsPercentage, level.isPresent else {
            return Size(width: cell, height: BatteryWidget.cellHeight)
        }
        let label = percentageLabel.intrinsicContentSize
        return Size(
            width: cell + BatteryWidget.labelSpacing + label.width,
            height: max(BatteryWidget.cellHeight, label.height))
    }

    public override func layout() {
        let label = percentageLabel.intrinsicContentSize
        percentageLabel.frame = Rect(
            x: BatteryWidget.cellWidth + BatteryWidget.terminalWidth
                + BatteryWidget.labelSpacing,
            y: (bounds.size.height - label.height) / 2,
            width: label.width,
            height: label.height)
    }

    // MARK: - Drawing

    public override func draw(in context: GraphicsContext) {
        guard level.isPresent else { return }

        // A hover backing, so the widget reads as a target before it is clicked.
        if isHovered {
            var backing = Path()
            backing.addRoundedRect(
                Rect(x: -4, y: 0, width: bounds.size.width + 8, height: bounds.size.height),
                radius: 4)
            context.fillColor = tintColor.opacity(0.12)
            context.fill(backing)
        }

        let top = (bounds.size.height - BatteryWidget.cellHeight) / 2
        let body = Rect(
            x: 0, y: top,
            width: BatteryWidget.cellWidth, height: BatteryWidget.cellHeight)

        // Outline, inset by half its width so it lands inside the cell rather
        // than straddling the edge.
        var outline = Path()
        outline.addRoundedRect(
            Rect(x: 0.5, y: top + 0.5,
                 width: body.size.width - 1, height: body.size.height - 1),
            radius: 2.5)
        context.strokeColor = tintColor.opacity(0.75)
        context.lineWidth = 1
        context.stroke(outline)

        // Terminal nub on the trailing edge.
        var terminal = Path()
        terminal.addRoundedRect(
            Rect(
                x: BatteryWidget.cellWidth,
                y: top + (BatteryWidget.cellHeight - BatteryWidget.terminalHeight) / 2,
                width: BatteryWidget.terminalWidth,
                height: BatteryWidget.terminalHeight),
            radius: 1)
        context.fillColor = tintColor.opacity(0.75)
        context.fill(terminal)

        if let charge = chargeFillRect() {
            var fill = Path()
            fill.addRoundedRect(charge, radius: 1)
            context.fillColor = fillColor
            context.fill(fill)
        }

        if level.isCharging { drawBolt(in: context, body: body) }
    }

    /// The charge fill's rectangle, or `nil` when there is nothing to fill.
    ///
    /// Separate from `draw` because this is the geometry worth checking: a path
    /// command carries its points in the payload blob, so the recording alone
    /// cannot say how wide the fill came out.
    ///
    /// Returns `nil` rather than a zero-width rect at empty — a rounded rect of
    /// zero width still paints its corners.
    func chargeFillRect() -> Rect? {
        guard level.isPresent, level.fraction > 0 else { return nil }
        let inset: Double = 2
        let top = (bounds.size.height - BatteryWidget.cellHeight) / 2
        let available = BatteryWidget.cellWidth - inset * 2
        let width = available * level.fraction
        guard width > 0 else { return nil }
        return Rect(
            x: inset, y: top + inset,
            width: width, height: BatteryWidget.cellHeight - inset * 2)
    }

    private var fillColor: Color {
        if level.isCharging { return chargingColor }
        return level.fraction <= warningThreshold ? warningColor : tintColor
    }

    /// A bolt over the cell while charging, so the state reads without relying
    /// on colour alone.
    private func drawBolt(in context: GraphicsContext, body: Rect) {
        let midX = body.size.width / 2
        let midY = body.origin.y + body.size.height / 2
        let height = BatteryWidget.cellHeight * 0.34
        let width = BatteryWidget.cellWidth * 0.13

        var bolt = Path()
        bolt.move(to: Point(x: midX + width * 0.4, y: midY - height))
        bolt.addLine(to: Point(x: midX - width, y: midY + height * 0.15))
        bolt.addLine(to: Point(x: midX, y: midY + height * 0.15))
        bolt.addLine(to: Point(x: midX - width * 0.4, y: midY + height))
        bolt.addLine(to: Point(x: midX + width, y: midY - height * 0.15))
        bolt.addLine(to: Point(x: midX, y: midY - height * 0.15))
        bolt.close()

        // Drawn in the background colour so it reads as cut out of the fill.
        context.fillColor = Color(0.05, 0.06, 0.09, 1)
        context.fill(bolt)
    }
}
