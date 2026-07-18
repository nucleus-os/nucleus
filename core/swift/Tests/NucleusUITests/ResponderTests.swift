@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite struct ResponderTests {
    final class TrackingView: View {
        var events: [Event] = []
        var result: EventHandling

        init(result: EventHandling = .notHandled) throws {
            self.result = result
            super.init()
        }

        override func handleEvent(_ event: Event) -> EventHandling {
            events.append(event)
            return result
        }
    }

    @Test func hitTestReturnsDeepestFrontmostSubview() throws {
        let root = View()
        let back = View()
        let front = View()

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))
        back.frame = (Rect(x: 10, y: 10, width: 80, height: 80))
        front.frame = (Rect(x: 20, y: 20, width: 20, height: 20))
        root.addSubview(back)
        root.addSubview(front)

        let hit = root.hitTest(Point(x: 25, y: 25))
        #expect(hit === front)
    }

    @Test func dispatchStopsAtHandledTarget() throws {
        let root = try TrackingView(result: .notHandled)
        let child = try TrackingView(result: .handled)

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))
        child.frame = (Rect(x: 0, y: 0, width: 50, height: 50))
        root.addSubview(child)

        let result = root.dispatchEvent(Event(type: .pointerDown, location: Point(x: 10, y: 10)))

        #expect(result == .handled)
        #expect(child.events.count == 1)
        #expect(root.events.count == 0)
    }

    @Test func dispatchBubblesToParentWhenTargetDoesNotHandle() throws {
        let root = try TrackingView(result: .handled)
        let child = try TrackingView(result: .notHandled)

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))
        child.frame = (Rect(x: 0, y: 0, width: 50, height: 50))
        root.addSubview(child)

        let result = root.dispatchEvent(Event(type: .pointerDown, location: Point(x: 10, y: 10)))

        #expect(result == .handled)
        #expect(child.events.count == 1)
        #expect(root.events.count == 1)
    }

    @Test func dispatchBubblesThroughViewControllerResponder() throws {
        final class HandlingViewController: ViewController {
            var events: [Event] = []

            override func handleEvent(_ event: Event) -> EventHandling {
                events.append(event)
                return .handled
            }
        }

        let window = Window(title: "Controller")
        let root = try TrackingView(result: .notHandled)
        let controller = HandlingViewController()

        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        controller.setView(root)
        window.setContentViewController(controller)

        let result = window.dispatchEvent(Event(type: .pointerDown, location: Point(x: 10, y: 10)))

        #expect(result == .handled)
        #expect(root.events.count == 1)
        #expect(controller.events.count == 1)
    }

    @Test func actionsBubbleThroughViewControllerResponder() throws {
        let root = View()
        let controller = ViewController()
        let action = ActionID(rawValue: 42)
        var performed = 0

        controller.setView(root)
        controller.setAction(action) { _ in
            performed += 1
        }

        root.performAction(action, event: Event(type: .action))

        #expect(performed == 1)
    }

    @Test func dispatchOutsideRootDoesNotHandle() throws {
        let root = try TrackingView(result: .handled)

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))

        let result = root.dispatchEvent(Event(type: .pointerDown, location: Point(x: 200, y: 200)))

        #expect(result == .notHandled)
        #expect(root.events.count == 0)
    }

    @Test func windowDispatchStartsFromRootView() throws {
        let window = Window(title: "Events")
        let root = try TrackingView(result: .handled)

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))
        window.setRootView(root)

        let result = window.dispatchEvent(Event(type: .pointerDown, location: Point(x: 1, y: 1)))

        #expect(result == .handled)
        #expect(root.events.count == 1)
    }

    @Test func buttonPressUsesResponderActionPath() throws {
        let button = Button(title: "OK")
        var pressed = 0

        button.frame = (Rect(x: 0, y: 0, width: 80, height: 30))
        button.onPress { sender in
            #expect(sender === button)
            pressed += 1
        }

        // A press then a release inside the button. The press has to happen:
        // a release with no press is a stray event, not a click.
        _ = button.dispatchEvent(
            Event(type: .pointerDown, location: Point(x: 10, y: 10)))
        let result = button.dispatchEvent(
            Event(type: .pointerUp, location: Point(x: 10, y: 10)))

        #expect(result == .handled)
        #expect(pressed == 1)
    }

    @Test func aReleaseWithoutAPressDoesNotFire() throws {
        let button = Button(title: "OK")
        var pressed = 0
        button.frame = Rect(x: 0, y: 0, width: 80, height: 30)
        button.onPress { _ in pressed += 1 }

        _ = button.dispatchEvent(
            Event(type: .pointerUp, location: Point(x: 10, y: 10)))
        #expect(pressed == 0)
    }

    /// Releasing outside the button cancels rather than fires. Previously the
    /// press latch cleared on any release wherever it landed, so dragging off a
    /// button and letting go still triggered it.
    ///
    /// Dispatched through a scene rather than the view: only scene dispatch
    /// holds a pointer capture, and without capture the outside release never
    /// reaches the button to be cancelled at all.
    @Test func releasingOutsideTheButtonCancels() throws {
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 300, height: 300)
        let button = Button(title: "OK")
        button.frame = Rect(x: 0, y: 0, width: 80, height: 30)
        var pressed = 0
        button.onPress { _ in pressed += 1 }
        root.addSubview(button)

        let window = Window(title: "Tracking")
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(windows: [window])

        _ = scene.dispatchEvent(Event(type: .pointerDown, location: Point(x: 10, y: 10)))
        #expect(button.isPressed)
        _ = scene.dispatchEvent(Event(type: .pointerUp, location: Point(x: 200, y: 200)))

        #expect(pressed == 0, "released outside: cancelled")
        #expect(!button.isPressed, "the latch cleared")
    }

    /// A right-click must not fire the primary action; it should be free to
    /// reach a context menu instead.
    @Test func aSecondaryButtonPressDoesNotFire() throws {
        let button = Button(title: "OK")
        var pressed = 0
        button.frame = Rect(x: 0, y: 0, width: 80, height: 30)
        button.onPress { _ in pressed += 1 }

        _ = button.dispatchEvent(
            Event(type: .pointerDown, location: Point(x: 10, y: 10), button: .right))
        _ = button.dispatchEvent(
            Event(type: .pointerUp, location: Point(x: 10, y: 10), button: .right))
        #expect(pressed == 0)
    }

    @Test func disabledButtonDoesNotHandlePress() throws {
        let button = Button(title: "Disabled")
        var pressed = false

        button.frame = (Rect(x: 0, y: 0, width: 80, height: 30))
        button.onPress { _ in
            pressed = true
        }
        button.isEnabled = false

        let result = button.dispatchEvent(Event(type: .pointerUp, location: Point(x: 10, y: 10)))

        #expect(result == .notHandled)
        #expect(!pressed)
    }
}
