import NucleusUI

/// The panel a battery widget opens: the same reading, spelled out.
///
/// Product tier, like the widget — it renders a `BatteryLevel` and never sees a
/// bus. The panel exists because a bar widget is a glyph and a number, and the
/// things a user actually wants ("how long have I got?", "is it charging?") do
/// not fit in twenty pixels.
@MainActor
public final class BatteryPanel: View {
    public private(set) var level: BatteryLevel

    private let headline: Label
    private let detail: Label

    private static let width: Double = 200

    public init(level: BatteryLevel) {
        self.level = level
        headline = Label("")
        detail = Label("")
        super.init()

        headline.font = .systemFont(ofSize: 15)
        headline.textColor = Color(0.94, 0.95, 0.98, 1)
        detail.font = .systemFont(ofSize: 12)
        // Dimmer than the headline: it is context, not the answer.
        detail.textColor = Color(0.94, 0.95, 0.98, 0.65)

        setBody {
            headline
            detail
        }
        apply()
    }

    public func update(_ level: BatteryLevel) {
        guard level != self.level else { return }
        self.level = level
        apply()
    }

    private func apply() {
        headline.text = headlineText
        detail.text = detailText
        detail.isHidden = detailText.isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    var headlineText: String {
        guard level.isPresent else { return "No battery" }
        return level.isCharging
            ? "\(level.percentageText) — charging"
            : level.percentageText
    }

    /// Empty when UPower has not worked out an estimate, which it has not for
    /// the first minute or so after a state change. Showing "0 min remaining"
    /// there would be a lie rather than a blank.
    var detailText: String {
        guard level.isPresent, let seconds = level.secondsRemaining else { return "" }
        let duration = BatteryWidget.durationText(seconds)
        return level.isCharging
            ? "\(duration) until full"
            : "\(duration) remaining"
    }

    public override var intrinsicContentSize: Size {
        let headlineSize = headline.intrinsicContentSize
        let detailSize = detailText.isEmpty
            ? Size.zero
            : detail.intrinsicContentSize
        let spacing: Double = detailText.isEmpty ? 0 : 4
        return Size(
            width: BatteryPanel.width,
            height: headlineSize.height + spacing + detailSize.height)
    }

    public override func layout() {
        let headlineSize = headline.intrinsicContentSize
        headline.frame = Rect(
            x: 0, y: 0, width: bounds.size.width, height: headlineSize.height)
        guard !detailText.isEmpty else { return }
        detail.frame = Rect(
            x: 0, y: headlineSize.height + 4,
            width: bounds.size.width,
            height: detail.intrinsicContentSize.height)
    }
}
