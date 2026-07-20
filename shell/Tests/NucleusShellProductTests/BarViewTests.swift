import Testing
import NucleusUI
@testable import NucleusShellProduct

/// A widget that reports what the framework asked of it.
@MainActor
private final class TestWidget: BarWidget {
    var refreshCount = 0
    var tickedSeconds: Double = 0
    var ticks = 0
    private let width: Double
    var animates = false

    init(width: Double = 40, capsule: Bool = true) {
        self.width = width
        super.init()
        showsCapsule = capsule
        frame = Rect(x: 0, y: 0, width: width, height: 20)
        layoutBasis = width
    }

    override var intrinsicContentSize: Size { Size(width: width, height: 20) }
    override var wantsFrameTick: Bool { animates }
    override func refresh() { refreshCount += 1 }
    override func frameTick(deltaSeconds: Double) {
        ticks += 1
        tickedSeconds += deltaSeconds
    }
}

/// The bar: three sections, chrome behind them, and the widget contract.
@MainActor
@Suite(.uiContext) struct BarViewTests {
    private func makeBar(width: Double = 400) -> BarView {
        let bar = BarView()
        bar.frame = Rect(x: 0, y: 0, width: width, height: 30)
        return bar
    }

    // MARK: - Sections

    @Test func startAndEndSectionsSitAtTheirEdges() {
        let bar = makeBar(width: 400)
        bar.setWidgets([TestWidget(width: 60)], in: .start)
        bar.setWidgets([TestWidget(width: 40)], in: .end)
        bar.layoutIfNeeded()

        let start = bar.widgets(in: .start)[0].barCoordinateFrame()
        let end = bar.widgets(in: .end)[0].barCoordinateFrame()
        #expect(start.origin.x == bar.edgeMargin)
        #expect(abs((end.origin.x + end.size.width) - (400 - bar.edgeMargin)) < 0.001)
    }

    /// The centre section is centred on the *bar*, not on the space left over.
    /// A clock that drifts when a tray icon appears is what flexible spacers
    /// produce, and it is the thing every status bar gets wrong.
    @Test func theCenterSectionIsCenteredOnTheBarNotTheRemainder() {
        let bar = makeBar(width: 400)
        bar.setWidgets([TestWidget(width: 200)], in: .start)
        bar.setWidgets([TestWidget(width: 40)], in: .center)
        bar.layoutIfNeeded()

        let center = bar.widgets(in: .center)[0].barCoordinateFrame()
        #expect(abs(center.origin.x + center.size.width / 2 - 200) < 0.001,
                "still centred despite a much wider start section")
    }

    @Test func theCenterStaysCenteredWhenTheBarResizes() {
        let bar = makeBar(width: 400)
        bar.setWidgets([TestWidget(width: 40)], in: .center)
        bar.layoutIfNeeded()

        bar.frame = Rect(x: 0, y: 0, width: 800, height: 30)
        bar.layoutIfNeeded()
        let center = bar.widgets(in: .center)[0].barCoordinateFrame()
        #expect(abs(center.origin.x + center.size.width / 2 - 400) < 0.001)
    }

    /// A vertical bar runs down a screen edge, and its sections run top, middle,
    /// bottom — which is why the sections are named along the axis.
    @Test func aVerticalBarStacksItsSections() {
        let bar = BarView()
        bar.axis = .vertical
        bar.frame = Rect(x: 0, y: 0, width: 30, height: 400)
        bar.setWidgets([TestWidget(width: 20)], in: .start)
        bar.setWidgets([TestWidget(width: 20)], in: .end)
        bar.layoutIfNeeded()

        let start = bar.widgets(in: .start)[0].barCoordinateFrame()
        let end = bar.widgets(in: .end)[0].barCoordinateFrame()
        #expect(start.origin.y < end.origin.y)
        #expect(start.origin.y == bar.edgeMargin)
    }

    @Test func replacingASectionDetachesTheOldWidgets() {
        let bar = makeBar()
        let first = TestWidget()
        bar.setWidgets([first], in: .start)
        bar.layoutIfNeeded()

        let second = TestWidget()
        bar.setWidgets([second], in: .start)
        #expect(bar.widgets(in: .start).count == 1)
        #expect(first.superview == nil, "the replaced widget left the tree")
    }

    // MARK: - Capsules

    /// Adjacency is the whole rule: a widget declining a capsule breaks the run
    /// rather than putting a hole in one.
    @Test func consecutiveCapsuleWidgetsShareOne() {
        let bar = makeBar()
        let a = TestWidget(capsule: true)
        let b = TestWidget(capsule: true)
        let bare = TestWidget(capsule: false)
        let d = TestWidget(capsule: true)
        bar.setWidgets([a, b, bare, d], in: .start)
        bar.layoutIfNeeded()

        let runs = bar.capsuleRuns(in: .start)
        #expect(runs.count == 2)
        #expect(runs[0].count == 2)
        #expect(runs[1].count == 1)
    }

    @Test func aSectionOfBareWidgetsHasNoCapsules() {
        let bar = makeBar()
        bar.setWidgets([TestWidget(capsule: false), TestWidget(capsule: false)], in: .start)
        bar.layoutIfNeeded()
        #expect(bar.capsuleRuns(in: .start).isEmpty)
    }

    /// A hidden widget is not there to be wrapped, and a capsule drawn around
    /// nothing would be a stray pill.
    @Test func aHiddenWidgetBreaksTheRunRatherThanJoiningIt() {
        let bar = makeBar()
        let a = TestWidget(capsule: true)
        let hidden = TestWidget(capsule: true)
        hidden.isHidden = true
        let c = TestWidget(capsule: true)
        bar.setWidgets([a, hidden, c], in: .start)
        bar.layoutIfNeeded()

        let runs = bar.capsuleRuns(in: .start)
        #expect(runs.count == 2, "the hidden widget splits the run")
        #expect(!runs.flatMap { $0 }.contains { $0 === hidden })
    }

    @Test func changingCapsuleParticipationRegroups() {
        let bar = makeBar()
        let a = TestWidget(capsule: true)
        let b = TestWidget(capsule: true)
        bar.setWidgets([a, b], in: .start)
        bar.layoutIfNeeded()
        #expect(bar.capsuleRuns(in: .start).count == 1)

        b.showsCapsule = false
        #expect(bar.capsuleRuns(in: .start).count == 1)
        #expect(bar.capsuleRuns(in: .start)[0].count == 1)
    }

    // MARK: - The widget contract

    @Test func refreshReachesEveryWidget() {
        let bar = makeBar()
        let a = TestWidget()
        let b = TestWidget()
        bar.setWidgets([a], in: .start)
        bar.setWidgets([b], in: .end)

        bar.refreshWidgets()
        #expect(a.refreshCount == 1)
        #expect(b.refreshCount == 1)
    }

    /// A bar of a dozen widgets each polling per frame never lets the compositor
    /// idle, so ticking is opt-in and only the widgets that asked are called.
    @Test func onlyAnimatingWidgetsAreTicked() {
        let bar = makeBar()
        let still = TestWidget()
        let animating = TestWidget()
        animating.animates = true
        bar.setWidgets([still, animating], in: .start)

        #expect(bar.wantsFrameTick)
        bar.frameTick(deltaSeconds: 0.016)
        #expect(animating.ticks == 1)
        #expect(still.ticks == 0)
        #expect(abs(animating.tickedSeconds - 0.016) < 0.0001)
    }

    @Test func aBarOfStillWidgetsWantsNoTick() {
        let bar = makeBar()
        bar.setWidgets([TestWidget(), TestWidget()], in: .start)
        #expect(!bar.wantsFrameTick)
    }

    /// A widget reports that it was activated and the bar decides what opens —
    /// the widget has no scene to present into.
    @Test func activationReportsTheWidgetsFrameInBarCoordinates() {
        let bar = makeBar(width: 400)
        let widget = TestWidget(width: 40)
        bar.setWidgets([widget], in: .end)
        bar.layoutIfNeeded()

        var anchor: Rect?
        widget.onActivateWidget = { _, rect in anchor = rect }
        widget.activate()

        let reported = anchor ?? .zero
        #expect(reported.size.width == 40)
        #expect(reported.origin.x > 300, "in the bar's coordinates, not the widget's own")
    }

    /// Outside a bar there is no bar space to report, so a widget falls back to
    /// its own frame rather than inventing one.
    @Test func aWidgetOutsideABarReportsItsOwnFrame() {
        let widget = TestWidget(width: 40)
        widget.frame = Rect(x: 5, y: 6, width: 40, height: 20)
        var anchor: Rect?
        widget.onActivateWidget = { _, rect in anchor = rect }
        widget.activate()
        #expect(anchor == Rect(x: 5, y: 6, width: 40, height: 20))
    }

    // MARK: - Chrome

    /// The chrome is a backdrop: a click belongs to the widget above it.
    @Test func theUnderlayIsNeverATarget() {
        let bar = makeBar()
        let widget = TestWidget(width: 60)
        bar.setWidgets([widget], in: .start)
        bar.layoutIfNeeded()

        // A point over the bar but outside every widget lands on the bar itself,
        // never on the chrome that is drawn there.
        let hit = bar.hitTest(Point(x: 350, y: 15))
        #expect(hit === bar)
    }

    @Test func aWidgetRemainsHittableThroughItsSection() {
        let bar = makeBar(width: 400)
        let widget = TestWidget(width: 60)
        bar.setWidgets([widget], in: .end)
        bar.layoutIfNeeded()

        let frame = widget.barCoordinateFrame()
        let middle = Point(
            x: frame.origin.x + frame.size.width / 2,
            y: frame.origin.y + frame.size.height / 2)
        #expect(bar.hitTest(middle) === widget)
    }
}
