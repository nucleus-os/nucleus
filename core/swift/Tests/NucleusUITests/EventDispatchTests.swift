import Testing
import NucleusUI

/// Event routing: two paths, as in AppKit. Keyboard-like events go to the key
/// window's first responder and up its chain; pointer events hit-test and then
/// traverse that view's chain, with a press capturing so the release reaches
/// the same view wherever the pointer ended up.
@MainActor
@Suite(.uiContext) struct EventDispatchTests {
    class RecordingView: View {
        var received: [EventType] = []
        var handles: Set<EventType> = []
        var focusable = false

        override var acceptsFirstResponder: Bool { focusable }

        override func handleEvent(_ event: Event) -> EventHandling {
            received.append(event.type)
            return handles.contains(event.type) ? .handled : .notHandled
        }
    }

    private func makeScene(
        root: View, frame: Rect = Rect(x: 0, y: 0, width: 100, height: 100)
    ) -> (WindowScene, Window) {
        let window = Window(title: "Scene")
        root.frame = frame
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        scene.makeKey(window)
        return (scene, window)
    }

    // MARK: - Keyboard

    @Test func keyEventsRouteToTheFirstResponderNotTheHitView() {
        let root = RecordingView()
        let focused = RecordingView()
        focused.focusable = true
        focused.handles = [.keyDown]
        focused.frame = Rect(x: 0, y: 0, width: 10, height: 10)
        root.addSubview(focused)
        let (scene, window) = makeScene(root: root)
        #expect(window.makeFirstResponder(focused))

        // Deliberately located far from `focused`: a key event must ignore the
        // pointer entirely.
        let handled = scene.dispatchEvent(
            Event(type: .keyDown, location: Point(x: 90, y: 90), keyCode: .escape))
        #expect(handled == .handled)
        #expect(focused.received == [.keyDown])
        #expect(root.received.isEmpty, "the key event never went through hit testing")
    }

    @Test func anUnhandledKeyEventClimbsTheResponderChain() {
        let root = RecordingView()
        root.handles = [.keyDown]
        let focused = RecordingView()
        focused.focusable = true
        focused.frame = Rect(x: 0, y: 0, width: 10, height: 10)
        root.addSubview(focused)
        let (scene, window) = makeScene(root: root)
        #expect(window.makeFirstResponder(focused))

        #expect(scene.dispatchEvent(Event(type: .keyDown, keyCode: .space)) == .handled)
        #expect(focused.received == [.keyDown], "offered to the first responder first")
        #expect(root.received.contains(.keyDown), "then to its parent")
    }

    @Test func keyEventsGoNowhereWithoutAKeyWindow() {
        let root = RecordingView()
        root.handles = [.keyDown]
        let window = Window(title: "Unfocused")
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])

        #expect(scene.dispatchEvent(Event(type: .keyDown)) == .notHandled)
        #expect(root.received.isEmpty)
    }

    // MARK: - First responder lifecycle

    @Test func aResponderThatRefusesToResignKeepsFocus() {
        final class Sticky: RecordingView {
            override func resignFirstResponder() -> Bool { false }
        }
        let root = RecordingView()
        let sticky = Sticky()
        sticky.focusable = true
        let other = RecordingView()
        other.focusable = true
        root.addSubview(sticky)
        root.addSubview(other)
        let (_, window) = makeScene(root: root)

        #expect(window.makeFirstResponder(sticky))
        #expect(!window.makeFirstResponder(other), "the move was refused")
        #expect(window.firstResponder === sticky, "focus did not move")
    }

    @Test func aViewThatDoesNotAcceptFocusIsRefused() {
        let root = RecordingView()
        let plain = RecordingView()  // focusable defaults to false
        root.addSubview(plain)
        let (_, window) = makeScene(root: root)

        #expect(!window.makeFirstResponder(plain))
        #expect(window.firstResponder !== plain)
    }

    /// A plain content view is not focusable, so it must not silently become
    /// first responder just by being installed — otherwise keys would land on a
    /// view that never asked for them.
    @Test func aNonFocusableContentViewDoesNotBecomeFirstResponder() {
        let window = Window(title: "Plain")
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 10, height: 10)
        window.setContentView(root)
        #expect(window.firstResponder == nil)
    }

    // MARK: - Pointer

    @Test func pointerEventsHitTestToAView() {
        let root = RecordingView()
        let target = RecordingView()
        target.handles = [.pointerDown]
        target.frame = Rect(x: 20, y: 20, width: 30, height: 30)
        root.addSubview(target)
        let (scene, _) = makeScene(root: root)

        #expect(scene.dispatchEvent(
            Event(type: .pointerDown, location: Point(x: 25, y: 25))) == .handled)
        #expect(target.received.contains(.pointerDown))
    }

    /// The location a view receives is its own, not the scene's.
    @Test func aViewReceivesViewLocalCoordinates() {
        final class LocationView: View {
            var lastLocation: Point?
            override func handleEvent(_ event: Event) -> EventHandling {
                if event.type == .pointerDown { lastLocation = event.location }
                return .handled
            }
        }
        let root = RecordingView()
        let target = LocationView()
        target.frame = Rect(x: 20, y: 20, width: 30, height: 30)
        root.addSubview(target)
        let (scene, _) = makeScene(root: root)

        _ = scene.dispatchEvent(Event(type: .pointerDown, location: Point(x: 25, y: 27)))
        #expect(target.lastLocation == Point(x: 5, y: 7))
    }

    @Test func capturedPointerSequenceStaysExactInANonzeroOriginWindow() {
        final class LocationView: View {
            var locations: [(EventType, Point)] = []

            override func handleEvent(_ event: Event) -> EventHandling {
                locations.append((event.type, event.location))
                return .handled
            }
        }

        let root = RecordingView()
        let container = View()
        container.frame = Rect(x: 30, y: 20, width: 120, height: 90)
        container.boundsOrigin = Point(x: 5, y: 8)
        let target = LocationView()
        target.frame = Rect(x: 15, y: 18, width: 40, height: 30)
        container.addSubview(target)
        root.addSubview(container)

        let window = Window(
            title: "Placed",
            frame: Rect(x: 400, y: 250, width: 300, height: 200)
        )
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])

        _ = scene.dispatchEvent(
            Event(type: .pointerDown, location: Point(x: 442, y: 283))
        )
        _ = scene.dispatchEvent(
            Event(type: .pointerDragged, location: Point(x: 457, y: 301))
        )
        _ = scene.dispatchEvent(
            Event(type: .pointerUp, location: Point(x: 475, y: 315))
        )

        #expect(target.locations.map(\.0) == [.pointerEntered, .pointerDown, .pointerDragged, .pointerUp])
        #expect(target.locations[1].1 == Point(x: 2, y: 3))
        #expect(target.locations[2].1 == Point(x: 17, y: 21))
        #expect(target.locations[3].1 == Point(x: 35, y: 35))
    }

    /// A press captures, so a release that lands outside still reaches the
    /// pressed view. Without this a control cannot tell "released on me" from
    /// "released elsewhere", and drag-cancel is impossible.
    @Test func aPressCapturesSoTheReleaseReachesTheSameView() {
        let root = RecordingView()
        root.handles = [.pointerUp]
        let target = RecordingView()
        target.handles = [.pointerDown, .pointerUp]
        target.frame = Rect(x: 0, y: 0, width: 10, height: 10)
        root.addSubview(target)
        let (scene, _) = makeScene(root: root)

        _ = scene.dispatchEvent(Event(type: .pointerDown, location: Point(x: 5, y: 5)))
        _ = scene.dispatchEvent(Event(type: .pointerUp, location: Point(x: 80, y: 80)))

        #expect(target.received.contains(.pointerUp), "the release reached the pressed view")
        #expect(!root.received.contains(.pointerUp), "and not the view under the pointer")
    }

    @Test func captureIsReleasedAfterThePointerGoesUp() {
        let root = RecordingView()
        root.handles = [.pointerDown]
        let target = RecordingView()
        target.handles = [.pointerDown, .pointerUp]
        target.frame = Rect(x: 0, y: 0, width: 10, height: 10)
        root.addSubview(target)
        let (scene, _) = makeScene(root: root)

        _ = scene.dispatchEvent(Event(type: .pointerDown, location: Point(x: 5, y: 5)))
        _ = scene.dispatchEvent(Event(type: .pointerUp, location: Point(x: 80, y: 80)))
        target.received.removeAll()

        // A fresh press far away must hit-test normally again. `target` still
        // sees `pointerExited` — the pointer did leave it — but must not see
        // the new press.
        _ = scene.dispatchEvent(Event(type: .pointerDown, location: Point(x: 80, y: 80)))
        #expect(!target.received.contains(.pointerDown), "capture did not persist past the release")
        #expect(root.received.contains(.pointerDown))
    }

    @Test func crossingViewsSendsExitThenEnter() {
        let root = RecordingView()
        let left = RecordingView()
        left.frame = Rect(x: 0, y: 0, width: 40, height: 100)
        let right = RecordingView()
        right.frame = Rect(x: 50, y: 0, width: 40, height: 100)
        root.addSubview(left)
        root.addSubview(right)
        let (scene, _) = makeScene(root: root)

        _ = scene.dispatchEvent(Event(type: .pointerMoved, location: Point(x: 10, y: 10)))
        #expect(left.received.contains(.pointerEntered))

        _ = scene.dispatchEvent(Event(type: .pointerMoved, location: Point(x: 60, y: 10)))
        #expect(left.received.contains(.pointerExited))
        #expect(right.received.contains(.pointerEntered))
    }

    @Test func scrollEventsReachTheViewUnderThePointer() {
        let root = RecordingView()
        let target = RecordingView()
        target.handles = [.scrollWheel]
        target.frame = Rect(x: 0, y: 0, width: 50, height: 50)
        root.addSubview(target)
        let (scene, _) = makeScene(root: root)

        let handled = scene.dispatchEvent(Event(
            type: .scrollWheel, location: Point(x: 10, y: 10),
            scrollDeltaY: -3, scrollSource: .finger))
        #expect(handled == .handled)
        #expect(target.received.contains(.scrollWheel))
    }
}
