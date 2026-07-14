@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite struct ResponderTests {
    final class TrackingView: View {
        var events: [Event] = []
        var result: EventHandling

        init(result: EventHandling = .notHandled) throws {
            self.result = result
            try super.init()
        }

        override func handleEvent(_ event: Event) throws(UIError) -> EventHandling {
            events.append(event)
            return result
        }
    }

    @Test func hitTestReturnsDeepestFrontmostSubview() throws {
        let root = try View()
        let back = try View()
        let front = try View()

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))
        back.frame = (Rect(x: 10, y: 10, width: 80, height: 80))
        front.frame = (Rect(x: 20, y: 20, width: 20, height: 20))
        try root.addSubview(back)
        try root.addSubview(front)

        let hit = try root.hitTest(Point(x: 25, y: 25))
        #expect(hit === front)
    }

    @Test func dispatchStopsAtHandledTarget() throws {
        let root = try TrackingView(result: .notHandled)
        let child = try TrackingView(result: .handled)

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))
        child.frame = (Rect(x: 0, y: 0, width: 50, height: 50))
        try root.addSubview(child)

        let result = try EventDispatcher.dispatch(Event(type: .pointerDown, location: Point(x: 10, y: 10)), from: root)

        #expect(result == .handled)
        #expect(child.events.count == 1)
        #expect(root.events.count == 0)
    }

    @Test func dispatchBubblesToParentWhenTargetDoesNotHandle() throws {
        let root = try TrackingView(result: .handled)
        let child = try TrackingView(result: .notHandled)

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))
        child.frame = (Rect(x: 0, y: 0, width: 50, height: 50))
        try root.addSubview(child)

        let result = try EventDispatcher.dispatch(Event(type: .pointerDown, location: Point(x: 10, y: 10)), from: root)

        #expect(result == .handled)
        #expect(child.events.count == 1)
        #expect(root.events.count == 1)
    }

    @Test func dispatchBubblesThroughViewControllerResponder() throws {
        final class HandlingViewController: ViewController {
            var events: [Event] = []

            override func handleEvent(_ event: Event) throws(UIError) -> EventHandling {
                events.append(event)
                return .handled
            }
        }

        let window = try Window(title: "Controller")
        let root = try TrackingView(result: .notHandled)
        let controller = try HandlingViewController()

        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        controller.setView(root)
        try window.setContentViewController(controller)

        let result = try window.dispatchEvent(Event(type: .pointerDown, location: Point(x: 10, y: 10)))

        #expect(result == .handled)
        #expect(root.events.count == 1)
        #expect(controller.events.count == 1)
    }

    @Test func actionsBubbleThroughViewControllerResponder() throws {
        let root = try View()
        let controller = try ViewController()
        let action = ActionID(rawValue: 42)
        var performed = 0

        controller.setView(root)
        try controller.setAction(action) { _ in
            performed += 1
        }

        try root.performAction(action, event: Event(type: .action))

        #expect(performed == 1)
    }

    @Test func dispatchOutsideRootDoesNotHandle() throws {
        let root = try TrackingView(result: .handled)

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))

        let result = try EventDispatcher.dispatch(Event(type: .pointerDown, location: Point(x: 200, y: 200)), from: root)

        #expect(result == .notHandled)
        #expect(root.events.count == 0)
    }

    @Test func windowDispatchStartsFromRootView() throws {
        let window = try Window(title: "Events")
        let root = try TrackingView(result: .handled)

        root.frame = (Rect(x: 0, y: 0, width: 100, height: 100))
        try window.setRootView(root)

        let result = try window.dispatchEvent(Event(type: .pointerDown, location: Point(x: 1, y: 1)))

        #expect(result == .handled)
        #expect(root.events.count == 1)
    }

    @Test func buttonPressUsesResponderActionPath() throws {
        let button = try Button(title: "OK")
        var pressed = 0

        button.frame = (Rect(x: 0, y: 0, width: 80, height: 30))
        try button.onPress { sender in
            #expect(sender === button)
            pressed += 1
        }

        let result = try EventDispatcher.dispatch(Event(type: .pointerUp, location: Point(x: 10, y: 10)), from: button)

        #expect(result == .handled)
        #expect(pressed == 1)
    }

    @Test func disabledButtonDoesNotHandlePress() throws {
        let button = try Button(title: "Disabled")
        var pressed = false

        button.frame = (Rect(x: 0, y: 0, width: 80, height: 30))
        try button.onPress { _ in
            pressed = true
        }
        button.isEnabled = false

        let result = try EventDispatcher.dispatch(Event(type: .pointerUp, location: Point(x: 10, y: 10)), from: button)

        #expect(result == .notHandled)
        #expect(!pressed)
    }
}
