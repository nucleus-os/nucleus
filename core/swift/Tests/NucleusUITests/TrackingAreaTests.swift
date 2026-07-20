import Testing
import NucleusUI

/// Tracking areas, cursors, and tooltips: what a bar widget needs to respond to
/// a pointer resting on it.
@MainActor
@Suite(.uiContext) struct TrackingAreaTests {
    private func makeScene(
        root: View, frame: Rect = Rect(x: 0, y: 0, width: 200, height: 100)
    ) -> WindowScene {
        let window = Window(title: "Scene")
        root.frame = frame
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.makeKey(window)
        return scene
    }

    private func move(_ scene: WindowScene, to point: Point, at nanos: UInt64 = 0) {
        scene.dispatchEvent(
            Event(type: .pointerMoved, location: point, timestampNanoseconds: nanos))
    }

    // MARK: - The area itself

    /// A `nil` rect tracks the whole view however it is later resized, which is
    /// what a widget wants — otherwise every owner has to re-set a rect from
    /// `layout()`.
    @Test func aWholeBoundsAreaFollowsTheViewsSize() {
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 50, height: 20)
        let area = view.addTracking()

        #expect(area.contains(Point(x: 40, y: 10), in: view))
        #expect(!area.contains(Point(x: 60, y: 10), in: view))

        view.frame = Rect(x: 0, y: 0, width: 100, height: 20)
        #expect(area.contains(Point(x: 60, y: 10), in: view), "it grew with the view")
    }

    @Test func anExplicitRectTracksOnlyItself() {
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let area = TrackingArea(rect: Rect(x: 10, y: 10, width: 20, height: 20))
        view.addTrackingArea(area)

        #expect(view.trackingArea(at: Point(x: 15, y: 15)) === area)
        #expect(view.trackingArea(at: Point(x: 50, y: 50)) == nil)
    }

    /// Areas are in bounds coordinates, so they move with a scrolled view's
    /// contents rather than staying where they were first placed.
    @Test func areasAreInBoundsCoordinates() {
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let area = TrackingArea(rect: Rect(x: 0, y: 50, width: 100, height: 20))
        view.addTrackingArea(area)

        #expect(view.trackingArea(at: Point(x: 10, y: 55)) === area)
        view.boundsOrigin = Point(x: 0, y: 40)
        // The same content is now at y 10 on screen, but the area's own
        // coordinates are unchanged.
        #expect(view.trackingArea(at: Point(x: 10, y: 55)) === area)
    }

    /// Removing the last area ends the hover, rather than leaving a view stuck
    /// looking hovered with nothing left to un-hover it.
    @Test func removingAnAreaClearsHover() {
        let root = View()
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 50, height: 50)
        let area = view.addTracking()
        root.addSubview(view)
        let scene = makeScene(root: root)

        move(scene, to: Point(x: 10, y: 10))
        #expect(view.isHovered)

        view.removeTrackingArea(area)
        #expect(view.trackingAreas.isEmpty)
        #expect(!view.isHovered)
    }

    // MARK: - Hover

    @Test func enteringAndLeavingFlipsHover() {
        let root = View()
        let child = View()
        child.frame = Rect(x: 10, y: 10, width: 30, height: 30)
        child.addTracking()
        root.addSubview(child)
        let scene = makeScene(root: root)

        move(scene, to: Point(x: 20, y: 20))
        #expect(child.isHovered)

        move(scene, to: Point(x: 100, y: 80))
        #expect(!child.isHovered)
    }

    @Test func disconnectReleasesHoveredSemanticTrees() throws {
        var root: View? = View()
        var child: View? = View()
        child!.frame = Rect(x: 10, y: 10, width: 30, height: 30)
        child!.addTracking()
        root!.addSubview(child!)
        var window: Window? = Window(title: "Teardown")
        root!.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        window!.setContentView(root!)
        window!.orderFront()
        let scene = WindowScene(inMemoryWindows: [window!])
        move(scene, to: Point(x: 20, y: 20))
        #expect(child!.isHovered)

        weak let weakRoot = root
        weak let weakChild = child
        weak let weakWindow = window
        try scene.disconnect()
        root = nil
        child = nil
        window = nil

        #expect(weakRoot == nil)
        #expect(weakChild == nil)
        #expect(weakWindow == nil)
    }

    /// Hover is a chain. A widget stays hovered while the pointer is over the
    /// label inside it — one that lit up only when the pointer missed its own
    /// text would be useless.
    @Test func hoverAppliesToTheWholeChain() {
        let root = View()
        let widget = View()
        widget.frame = Rect(x: 0, y: 0, width: 80, height: 40)
        widget.addTracking()
        let label = View()
        label.frame = Rect(x: 5, y: 5, width: 30, height: 20)
        label.addTracking()
        widget.addSubview(label)
        root.addSubview(widget)
        let scene = makeScene(root: root)

        move(scene, to: Point(x: 10, y: 10))
        #expect(label.isHovered)
        #expect(widget.isHovered, "the widget did not stop being hovered")
    }

    /// A view with no tracking area never reports hover, so adding tracking is
    /// an opt-in rather than a cost every view pays.
    @Test func aViewWithoutTrackingIsNeverHovered() {
        let root = View()
        let plain = View()
        plain.frame = Rect(x: 0, y: 0, width: 50, height: 50)
        root.addSubview(plain)
        let scene = makeScene(root: root)

        move(scene, to: Point(x: 10, y: 10))
        #expect(!plain.isHovered)
    }

    @Test func leavingEveryWindowClearsHover() {
        let root = View()
        let child = View()
        child.frame = Rect(x: 0, y: 0, width: 20, height: 20)
        child.addTracking()
        root.addSubview(child)
        let scene = makeScene(root: root)

        move(scene, to: Point(x: 10, y: 10))
        #expect(child.isHovered)

        // Outside every window.
        move(scene, to: Point(x: 5000, y: 5000))
        #expect(!child.isHovered)
    }

    /// A control is hoverable without being asked — one that had to be asked is
    /// one most callers would forget to ask.
    @Test func controlsTrackByDefault() {
        let control = Control()
        control.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        let root = View()
        root.addSubview(control)
        let scene = makeScene(root: root)

        move(scene, to: Point(x: 10, y: 10))
        #expect(control.isHovered)
    }

    /// A disabled control does not report hover: the state signals "this
    /// responds", and a disabled one does not.
    @Test func aDisabledControlDoesNotHover() {
        let control = Control()
        control.isEnabled = false
        control.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        let root = View()
        root.addSubview(control)
        let scene = makeScene(root: root)

        move(scene, to: Point(x: 10, y: 10))
        #expect(!control.isHovered)
    }

    // MARK: - Cursors

    @Test func theCursorFollowsTheInnermostAreaThatNamesOne() {
        let root = View()
        let outer = View()
        outer.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        outer.addTracking(cursor: .grab)
        let inner = View()
        inner.frame = Rect(x: 0, y: 0, width: 20, height: 20)
        inner.addTracking(cursor: .text)
        outer.addSubview(inner)
        root.addSubview(outer)
        let scene = makeScene(root: root)

        move(scene, to: Point(x: 10, y: 10))
        #expect(scene.cursor == .text, "the innermost wins")

        move(scene, to: Point(x: 50, y: 50))
        #expect(scene.cursor == .grab)
    }

    /// An area with no cursor inherits rather than resetting to the arrow.
    @Test func anAreaWithoutACursorInherits() {
        let root = View()
        let outer = View()
        outer.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        outer.addTracking(cursor: .pointingHand)
        let inner = View()
        inner.frame = Rect(x: 0, y: 0, width: 20, height: 20)
        inner.addTracking()
        outer.addSubview(inner)
        root.addSubview(outer)
        let scene = makeScene(root: root)

        move(scene, to: Point(x: 10, y: 10))
        #expect(scene.cursor == .pointingHand)
    }

    @Test func leavingEverythingRestoresTheArrow() {
        let root = View()
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 20, height: 20)
        view.addTracking(cursor: .text)
        root.addSubview(view)
        let scene = makeScene(root: root)

        var changes: [Cursor] = []
        scene.onCursorChange = { changes.append($0) }

        move(scene, to: Point(x: 5, y: 5))
        move(scene, to: Point(x: 150, y: 90))
        #expect(scene.cursor == .arrow)
        #expect(changes == [.text, .arrow], "no redundant notifications")
    }

    // MARK: - Tooltips

    /// A tooltip appears only after the pointer has rested, and the rest is
    /// measured from when the pointer arrived.
    @Test func aToolTipAppearsAfterTheDelay() {
        let root = View()
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        view.addTracking(toolTip: "Battery 73%")
        root.addSubview(view)
        let scene = makeScene(root: root)

        var shown: [String?] = []
        scene.onToolTipChange = { text, _ in shown.append(text) }

        move(scene, to: Point(x: 10, y: 10), at: 1_000)
        scene.updateToolTip(atNanoseconds: 1_000)
        #expect(shown.isEmpty, "not yet")

        scene.updateToolTip(atNanoseconds: 1_000 + scene.toolTipDelayNanoseconds)
        #expect(shown == ["Battery 73%"])

        // Idempotent once shown.
        scene.updateToolTip(atNanoseconds: 5_000_000_000)
        #expect(shown == ["Battery 73%"])
    }

    /// The provider runs when the tooltip is about to appear, not when it is
    /// configured — the interesting tooltips are live.
    @Test func theProviderIsCalledAtDisplayTime() {
        let root = View()
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        var reading = 50
        view.addTracking(toolTipProvider: { "\(reading)%" })
        root.addSubview(view)
        let scene = makeScene(root: root)

        var shown: String?
        scene.onToolTipChange = { text, _ in shown = text }

        reading = 73
        move(scene, to: Point(x: 10, y: 10), at: 0)
        scene.updateToolTip(atNanoseconds: scene.toolTipDelayNanoseconds)
        #expect(shown == "73%", "read at display time, not at setup")
    }

    /// A provider returning nil suppresses the tooltip for this hover.
    @Test func aNilProviderResultShowsNothing() {
        let root = View()
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        view.addTracking(toolTipProvider: { nil })
        root.addSubview(view)
        let scene = makeScene(root: root)

        var calls = 0
        scene.onToolTipChange = { _, _ in calls += 1 }
        move(scene, to: Point(x: 10, y: 10), at: 0)
        scene.updateToolTip(atNanoseconds: scene.toolTipDelayNanoseconds)
        #expect(calls == 0)
    }

    /// Moving to a different area hides the tooltip and restarts the timer, so
    /// a tooltip never describes the thing the pointer just left.
    @Test func movingToAnotherAreaHidesAndRestarts() {
        let root = View()
        let left = View()
        left.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        left.addTracking(toolTip: "Left")
        let right = View()
        right.frame = Rect(x: 60, y: 0, width: 40, height: 20)
        right.addTracking(toolTip: "Right")
        root.addSubview(left)
        root.addSubview(right)
        let scene = makeScene(root: root)

        var shown: [String?] = []
        scene.onToolTipChange = { text, _ in shown.append(text) }

        move(scene, to: Point(x: 10, y: 10), at: 0)
        scene.updateToolTip(atNanoseconds: scene.toolTipDelayNanoseconds)
        #expect(shown == ["Left"])

        move(scene, to: Point(x: 70, y: 10), at: 10_000_000_000)
        #expect(shown == ["Left", nil], "the old tooltip went away immediately")

        scene.updateToolTip(atNanoseconds: 10_000_000_000)
        #expect(shown == ["Left", nil], "the timer restarted")

        scene.updateToolTip(
            atNanoseconds: 10_000_000_000 + scene.toolTipDelayNanoseconds)
        #expect(shown == ["Left", nil, "Right"])
    }

    /// Moving inside the same area does not restart the timer, or a tooltip
    /// would never appear for anyone whose hand is not perfectly still.
    @Test func movingWithinAnAreaKeepsTheTimerRunning() {
        let root = View()
        let view = View()
        view.frame = Rect(x: 0, y: 0, width: 80, height: 40)
        view.addTracking(toolTip: "Steady")
        root.addSubview(view)
        let scene = makeScene(root: root)

        var shown: [String?] = []
        scene.onToolTipChange = { text, _ in shown.append(text) }

        move(scene, to: Point(x: 10, y: 10), at: 0)
        move(scene, to: Point(x: 12, y: 11), at: 100)
        move(scene, to: Point(x: 14, y: 12), at: 200)
        scene.updateToolTip(atNanoseconds: scene.toolTipDelayNanoseconds)
        #expect(shown == ["Steady"])
    }

    /// The anchor is the tracked area, not the pointer, so a tooltip does not
    /// jitter as the pointer moves within a widget.
    @Test func theAnchorIsTheAreaNotThePointer() {
        let root = View()
        let view = View()
        view.frame = Rect(x: 30, y: 12, width: 40, height: 20)
        view.addTracking(toolTip: "Anchored")
        root.addSubview(view)
        let scene = makeScene(root: root)

        var anchor: Rect = .zero
        scene.onToolTipChange = { _, rect in anchor = rect }

        move(scene, to: Point(x: 35, y: 15), at: 0)
        scene.updateToolTip(atNanoseconds: scene.toolTipDelayNanoseconds)
        #expect(anchor == Rect(x: 30, y: 12, width: 40, height: 20))
    }

    @Test func tooltipAnchorIncludesANonzeroWindowPlacementOnce() {
        let root = View()
        let view = View()
        view.frame = Rect(x: 30, y: 12, width: 40, height: 20)
        view.addTracking(toolTip: "Anchored")
        root.addSubview(view)

        let window = Window(
            title: "Placed",
            frame: Rect(x: 500, y: 300, width: 200, height: 100)
        )
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])

        var anchor: Rect = .zero
        scene.onToolTipChange = { _, rect in anchor = rect }

        move(scene, to: Point(x: 535, y: 315), at: 0)
        scene.updateToolTip(atNanoseconds: scene.toolTipDelayNanoseconds)
        #expect(anchor == Rect(x: 530, y: 312, width: 40, height: 20))
    }
}
