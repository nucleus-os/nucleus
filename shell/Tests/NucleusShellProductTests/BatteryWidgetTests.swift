import Testing
import NucleusUI
import NucleusUIEmbedder
import NucleusTypes
@testable import NucleusShellProduct

/// The battery widget. It renders a value type and nothing else — no bus, no
/// service — so every case a real machine takes weeks to produce is one
/// assignment away.
@MainActor
@Suite struct BatteryWidgetTests {
    private func makeWidget(_ level: BatteryLevel) -> BatteryWidget {
        let widget = BatteryWidget()
        widget.update(level)
        widget.frame = Rect(x: 0, y: 0, width: 60, height: 20)
        widget.layoutIfNeeded()
        return widget
    }

    private func commands(_ widget: BatteryWidget) -> [PaintCommand] {
        widget.displayIfNeeded()
        return widget.recordedDrawing.paintCommands
    }

    // MARK: - The value type

    /// A service reporting 101% must not draw a fill wider than the cell.
    @Test func theFractionIsClampedOnConstruction() {
        #expect(BatteryLevel(fraction: 1.4).fraction == 1)
        #expect(BatteryLevel(fraction: -0.5).fraction == 0)
    }

    @Test func percentageTextRounds() {
        #expect(BatteryLevel(fraction: 0.734).percentageText == "73%")
        #expect(BatteryLevel(fraction: 0.736).percentageText == "74%")
        #expect(BatteryLevel(fraction: 1).percentageText == "100%")
    }

    // MARK: - Absence

    /// A desktop has no battery. That is not zero percent, and the widget hides
    /// rather than drawing an empty cell.
    @Test func anAbsentBatteryHidesTheWidget() {
        let widget = makeWidget(.absent)
        #expect(widget.isHidden)
        #expect(commands(widget).isEmpty, "nothing is drawn")
    }

    @Test func aPresentBatteryShowsTheWidget() {
        let widget = makeWidget(BatteryLevel(fraction: 0.5))
        #expect(!widget.isHidden)
        #expect(!commands(widget).isEmpty)
    }

    // MARK: - Drawing

    /// Outline, terminal, and fill. A charged battery draws all three.
    @Test func aChargedBatteryDrawsItsCellAndFill() {
        let widget = makeWidget(BatteryLevel(fraction: 0.8))
        let drawn = commands(widget)
        #expect(drawn.count >= 3)
        #expect(drawn.contains { $0.flags.contains(.stroke) }, "the outline")
        #expect(drawn.contains { !$0.flags.contains(.stroke) }, "the fill")
    }

    /// An empty battery draws no fill — a zero-width rounded rect would still
    /// paint its corners.
    @Test func anEmptyBatteryDrawsNoFill() {
        let empty = commands(makeWidget(BatteryLevel(fraction: 0)))
        let half = commands(makeWidget(BatteryLevel(fraction: 0.5)))
        #expect(empty.count < half.count, "one fewer painted shape")
    }

    /// Charging adds the bolt, so the state reads without relying on colour —
    /// which matters for anyone who cannot distinguish the two fills.
    @Test func chargingDrawsABoltOverTheCell() {
        let discharging = commands(makeWidget(
            BatteryLevel(fraction: 0.5, isCharging: false)))
        let charging = commands(makeWidget(
            BatteryLevel(fraction: 0.5, isCharging: true)))
        #expect(charging.count == discharging.count + 1)
    }

    /// The fraction reaches the geometry. Asserted on the computed rectangle
    /// rather than the recording: a path command carries its points in the
    /// payload blob, so `PaintCommand.w` says nothing about how wide the fill is.
    @Test func theFillWidthTracksTheFraction() throws {
        let low = try #require(makeWidget(BatteryLevel(fraction: 0.1)).chargeFillRect())
        let high = try #require(makeWidget(BatteryLevel(fraction: 0.9)).chargeFillRect())
        #expect(high.size.width > low.size.width)

        // Full charge fills the cell inside its inset, and no further.
        let full = try #require(makeWidget(BatteryLevel(fraction: 1)).chargeFillRect())
        #expect(full.size.width == 22 - 4)
        #expect(full.origin.x == 2)
    }

    @Test func anEmptyBatteryHasNoFillRectangle() {
        #expect(makeWidget(BatteryLevel(fraction: 0)).chargeFillRect() == nil)
        #expect(makeWidget(.absent).chargeFillRect() == nil)
    }

    // MARK: - Update path

    /// The whole update path: assign a value, and the retained views change.
    /// No tree, no diff.
    @Test func updatingChangesTheLabelInPlace() {
        let widget = makeWidget(BatteryLevel(fraction: 0.5))
        let label = widget.percentageLabel
        #expect(label.text == "50%")

        widget.update(BatteryLevel(fraction: 0.25))
        #expect(label.text == "25%")
        #expect(widget.percentageLabel === label, "still the same object")
    }

    @Test func anIdenticalUpdateIsANoOp() {
        let widget = makeWidget(BatteryLevel(fraction: 0.5))
        widget.displayIfNeeded()
        #expect(!widget.needsDisplay)

        widget.update(BatteryLevel(fraction: 0.5))
        #expect(!widget.needsDisplay, "nothing changed, nothing to redraw")

        widget.update(BatteryLevel(fraction: 0.6))
        #expect(widget.needsDisplay)
    }

    @Test func hidingThePercentageShrinksTheWidget() {
        let widget = makeWidget(BatteryLevel(fraction: 0.5))
        let withLabel = widget.intrinsicContentSize.width

        widget.showsPercentage = false
        #expect(widget.intrinsicContentSize.width < withLabel)
        #expect(widget.percentageLabel.isHidden)
    }

    // MARK: - Tracking

    /// The widget is a hover target with a cursor and a live tooltip — the gap
    /// that motivated the tracking work.
    @Test func theWidgetTracksThePointer() throws {
        let widget = makeWidget(BatteryLevel(fraction: 0.5))
        let area = try #require(widget.trackingAreas.first)
        #expect(area.cursor == .pointingHand)
    }

    /// The tooltip is a provider, so it describes the reading at the moment the
    /// pointer rests rather than the one current when the widget was built.
    @Test func theToolTipReflectsTheCurrentReading() throws {
        let widget = makeWidget(BatteryLevel(fraction: 0.5))
        let area = try #require(widget.trackingAreas.first)
        #expect(area.resolvedToolTip() == "Battery 50%")

        widget.update(BatteryLevel(fraction: 0.2, isCharging: true))
        #expect(area.resolvedToolTip() == "Battery 20%, charging")
    }

    // MARK: - The panel

    /// The widget reports its click rather than presenting anything: it has no
    /// scene, and one that reached for a scene could not be tested by
    /// assignment.
    @Test func clickingReportsAnAnchor() {
        let widget = makeWidget(BatteryLevel(fraction: 0.5))
        // The anchor is compared inside the closure: `Rect` is ambiguous in this
        // file (NucleusTypes declares one too), so the types stay inferred.
        var anchorWasBounds = false
        var activations = 0
        widget.onActivate = { widget, rect in
            activations += 1
            anchorWasBounds = (rect == widget.bounds)
        }

        widget.dispatchEvent(Event(type: .pointerDown, location: Point(x: 5, y: 5)))
        #expect(activations == 1)
        #expect(anchorWasBounds, "anchored to the widget, not the pointer")
    }

    /// An absent battery has nothing to explain, so it does not open a panel.
    @Test func anAbsentBatteryDoesNotActivate() {
        let widget = makeWidget(.absent)
        var activated = false
        widget.onActivate = { _, _ in activated = true }

        widget.dispatchEvent(Event(type: .pointerDown, location: Point(x: 5, y: 5)))
        #expect(!activated)
    }

    @Test func thePanelSpellsOutTheReading() {
        let widget = makeWidget(
            BatteryLevel(fraction: 0.4, secondsRemaining: 5400))
        let panel = widget.makePanel()
        #expect(panel.headlineText == "40%")
        #expect(panel.detailText == "1 hr 30 min remaining")
    }

    @Test func aChargingPanelSaysSoAndCountsUp() {
        let widget = makeWidget(
            BatteryLevel(fraction: 0.4, isCharging: true, secondsRemaining: 1800))
        let panel = widget.makePanel()
        #expect(panel.headlineText == "40% — charging")
        #expect(panel.detailText == "30 min until full")
    }

    /// UPower reports no estimate for the first minute or so after a state
    /// change. "0 min remaining" there would be a lie rather than a blank.
    @Test func anUnknownEstimateShowsNoDetail() {
        let widget = makeWidget(BatteryLevel(fraction: 0.4))
        #expect(widget.makePanel().detailText.isEmpty)
    }

    // MARK: - Accessibility

    /// A drawn cell says nothing to an assistive technology, and a bare "73%"
    /// does not say 73% of what.
    @Test func theWidgetDescribesItselfInWords() {
        #expect(makeWidget(.absent).accessibilityLabel == "No battery")
        #expect(makeWidget(BatteryLevel(fraction: 0.73)).accessibilityLabel
                == "Battery 73%")
        #expect(makeWidget(BatteryLevel(fraction: 0.4, isCharging: true))
                .accessibilityLabel == "Battery 40%, charging")
        #expect(makeWidget(BatteryLevel(fraction: 0.4, secondsRemaining: 5400))
                .accessibilityLabel == "Battery 40%, 1 hr 30 min remaining")
    }

    /// A battery estimate is coarse, so reporting it to the second would be
    /// false precision.
    @Test func durationsReadCoarsely() {
        #expect(BatteryWidget.durationText(90) == "1 min")
        #expect(BatteryWidget.durationText(3600) == "1 hr")
        #expect(BatteryWidget.durationText(5400) == "1 hr 30 min")
        #expect(BatteryWidget.durationText(0) == "0 min")
    }
}
