import Testing
@testable import NucleusUI

@MainActor
@Suite(.uiContext) struct InputSequenceTests {
    private final class RecordingView: View {
        var events: [Event] = []
        var handled: Set<EventType> = []

        override func handleEvent(_ event: Event) -> EventHandling {
            events.append(event)
            return handled.contains(event.type) ? .handled : .notHandled
        }
    }

    private final class ExplicitCaptureView: View {
        var events: [EventType] = []

        override func handleEvent(_ event: Event) -> EventHandling {
            events.append(event.type)
            return event.type == .pointerDown ? .capture : .handled
        }
    }

    private func makeScene(root: View) -> WindowScene {
        root.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        let window = Window(title: "Input")
        window.setContentView(root)
        window.orderFront()
        return WindowScene(inMemoryWindows: [window])
    }

    @Test func twoTouchSequencesKeepIndependentCaptureTargets() {
        let root = View()
        let left = RecordingView()
        left.handled = [.touchDown, .touchMoved, .touchUp]
        left.frame = Rect(x: 0, y: 0, width: 90, height: 100)
        let right = RecordingView()
        right.handled = [.touchDown, .touchMoved, .touchUp]
        right.frame = Rect(x: 110, y: 0, width: 90, height: 100)
        root.addSubview(left)
        root.addSubview(right)
        let scene = makeScene(root: root)

        _ = scene.dispatchEvent(Event(
            type: .touchDown,
            location: Point(x: 10, y: 10),
            sequenceID: InputSequenceID(rawValue: 1),
            pointerTool: .finger))
        _ = scene.dispatchEvent(Event(
            type: .touchDown,
            location: Point(x: 120, y: 20),
            sequenceID: InputSequenceID(rawValue: 2),
            pointerTool: .finger))
        _ = scene.dispatchEvent(Event(
            type: .touchMoved,
            location: Point(x: 150, y: 30),
            sequenceID: InputSequenceID(rawValue: 1),
            pointerTool: .finger))
        _ = scene.dispatchEvent(Event(
            type: .touchMoved,
            location: Point(x: 20, y: 40),
            sequenceID: InputSequenceID(rawValue: 2),
            pointerTool: .finger))

        #expect(left.events.map(\.type) == [.touchDown, .touchMoved])
        #expect(right.events.map(\.type) == [.touchDown, .touchMoved])
        #expect(left.events.last?.sequenceID.rawValue == 1)
        #expect(right.events.last?.sequenceID.rawValue == 2)
    }

    @Test func anUnhandledDownDoesNotCapture() {
        let root = View()
        let left = RecordingView()
        left.frame = Rect(x: 0, y: 0, width: 90, height: 100)
        let right = RecordingView()
        right.handled = [.pointerUp]
        right.frame = Rect(x: 110, y: 0, width: 90, height: 100)
        root.addSubview(left)
        root.addSubview(right)
        let scene = makeScene(root: root)

        #expect(scene.dispatchEvent(Event(
            type: .pointerDown,
            location: Point(x: 10, y: 10))) == .notHandled)
        #expect(scene.dispatchEvent(Event(
            type: .pointerUp,
            location: Point(x: 120, y: 10))) == .handled)
        #expect(!left.events.contains { $0.type == .pointerUp })
        #expect(right.events.contains { $0.type == .pointerUp })
    }

    @Test func explicitCaptureIsExternallyHandledAndRetainsTheSequence() {
        let root = View()
        let view = ExplicitCaptureView()
        view.frame = Rect(x: 0, y: 0, width: 50, height: 50)
        root.addSubview(view)
        let scene = makeScene(root: root)

        #expect(scene.dispatchEvent(Event(
            type: .pointerDown,
            location: Point(x: 10, y: 10))) == .handled)
        #expect(scene.dispatchEvent(Event(
            type: .pointerUp,
            location: Point(x: 150, y: 75))) == .handled)
        #expect(view.events.suffix(2) == [.pointerDown, .pointerUp])
    }

    @Test func removingCapturedSubtreeDeliversCancellationAndReleasesIt() {
        let root = View()
        var target: RecordingView? = RecordingView()
        target!.handled = [.pointerDown, .pointerCancelled]
        target!.frame = Rect(x: 0, y: 0, width: 50, height: 50)
        root.addSubview(target!)
        let scene = makeScene(root: root)
        weak let weakTarget = target

        _ = scene.dispatchEvent(Event(
            type: .pointerDown,
            location: Point(x: 10, y: 10)))
        target!.removeFromSuperview()
        #expect(target!.events.contains { $0.type == .pointerCancelled })
        target = nil
        #expect(weakTarget == nil)
    }

    @Test func eventCarriesNeutralDeviceToolAndPressureData() {
        let event = Event(
            type: .pointerDragged,
            deviceID: InputDeviceID(rawValue: 9),
            sequenceID: InputSequenceID(rawValue: 7),
            button: .left,
            activeButtons: [.left],
            pressure: 1.5,
            pointerTool: .stylus)
        #expect(event.deviceID.rawValue == 9)
        #expect(event.sequenceID.rawValue == 7)
        #expect(event.activeButtons == [.left])
        #expect(event.pressure == 1)
        #expect(event.pointerTool == .stylus)
    }
}

@MainActor
@Suite(.uiContext) struct ResponderCycleSafetyTests {
    private final class CyclicResponder: Responder {
        weak var peer: Responder?
        override var nextResponder: Responder? {
            get { peer }
            set { peer = newValue }
        }
    }

    @Test func rawEventCycleTerminatesAsUnhandled() {
        let a = CyclicResponder()
        let b = CyclicResponder()
        a.peer = b
        b.peer = a
        #expect(a.deliverEvent(Event(type: .keyDown)) == .notHandled)
    }

    @Test func actionCycleTerminatesAsUnhandled() {
        let a = CyclicResponder()
        let b = CyclicResponder()
        a.peer = b
        b.peer = a
        #expect(!a.performAction(
            ActionID(rawValue: 999),
            event: Event(type: .action)))
    }
}

@MainActor
@Suite(.uiContext) struct FocusScopeTests {
    private final class Focusable: View {
        override init() {
            super.init()
            isAccessibilityElement = true
            accessibilityRole = .button
        }

        override var acceptsFirstResponder: Bool { true }
    }

    @Test func modalScopeTrapsTraversalAndRestoresPriorStableFocus() {
        let root = View()
        let outside = Focusable()
        outside.focusKey = "outside"
        let scope = View()
        let insideA = Focusable()
        let insideB = Focusable()
        scope.addSubview(insideA)
        scope.addSubview(insideB)
        root.addSubview(outside)
        root.addSubview(scope)
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let window = Window(title: "Focus")
        window.setContentView(root)

        #expect(window.makeFirstResponder(outside))
        window.beginFocusScope(scope)
        #expect(window.firstResponder === insideA)
        #expect(!window.makeFirstResponder(outside))
        #expect(window.advanceFocus())
        #expect(window.firstResponder === insideB)
        #expect(window.advanceFocus())
        #expect(window.firstResponder === insideA)

        window.endFocusScope(scope)
        #expect(window.firstResponder === outside)
    }

    @Test func focusChangesInvalidateBothRingsAndNotifyAdapter() {
        let root = View()
        let a = Focusable()
        let b = Focusable()
        a.frame = Rect(x: 0, y: 0, width: 40, height: 30)
        b.frame = Rect(x: 50, y: 0, width: 40, height: 30)
        root.addSubview(a)
        root.addSubview(b)
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let window = Window(title: "Focus")
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])
        _ = scene.accessibilityTree.publish()

        a.displayIfNeeded()
        b.displayIfNeeded()
        #expect(window.makeFirstResponder(a))
        let firstUpdate = scene.accessibilityTree.publish()
        #expect(a.needsDisplay)
        a.displayIfNeeded()
        #expect(window.makeFirstResponder(b))
        let secondUpdate = scene.accessibilityTree.publish()
        #expect(a.needsDisplay)
        #expect(b.needsDisplay)
        #expect(firstUpdate.notifications.contains {
            $0.kind == .focus && $0.target == a.accessibilityID
        })
        #expect(secondUpdate.notifications.contains {
            $0.kind == .focus && $0.target == b.accessibilityID
        })
    }
}

@MainActor
@Suite(.uiContext) struct ControlKeyboardTests {
    @Test func spacePreservesPressedFeedbackUntilKeyUp() {
        let button = Button(title: "Run")
        button.frame = Rect(x: 0, y: 0, width: 80, height: 30)
        let window = Window(title: "Keys")
        window.setContentView(button)
        #expect(window.makeFirstResponder(button))
        var presses = 0
        button.onPress { _ in presses += 1 }

        #expect(button.handleEvent(Event(
            type: .keyDown, keyCode: .space)) == .handled)
        #expect(button.isPressed)
        #expect(presses == 0)
        #expect(button.handleEvent(Event(
            type: .keyUp, keyCode: .space)) == .handled)
        #expect(!button.isPressed)
        #expect(presses == 1)
    }

    @Test func returnActivatesDefaultButtonOutsideFocusChain() {
        let root = View()
        let field = TextField(string: "")
        let button = Button(title: "OK")
        button.isDefaultButton = true
        root.addSubview(field)
        root.addSubview(button)
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let window = Window(title: "Default")
        window.setContentView(root)
        #expect(window.makeFirstResponder(field))
        var presses = 0
        button.onPress { _ in presses += 1 }

        #expect(window.dispatchEvent(Event(
            type: .keyDown, keyCode: .return)) == .handled)
        #expect(presses == 1)
    }

    @Test func disablingCapturedControlClearsAndReleasesSequence() {
        let root = View()
        let control = Control()
        control.frame = Rect(x: 0, y: 0, width: 50, height: 50)
        root.addSubview(control)
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let window = Window(title: "Disable")
        window.setContentView(root)
        window.orderFront()
        let scene = WindowScene(inMemoryWindows: [window])

        _ = scene.dispatchEvent(Event(
            type: .pointerDown,
            location: Point(x: 10, y: 10)))
        #expect(control.isPressed)
        control.isEnabled = false
        #expect(!control.isPressed)
        #expect(!control.isHighlighted)
        #expect(scene.dispatchEvent(Event(
            type: .pointerUp,
            location: Point(x: 10, y: 10))) == .notHandled)
    }
}
