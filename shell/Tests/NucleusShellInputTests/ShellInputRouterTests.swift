import Testing
import NucleusUI
import NucleusShellWayland
@testable import NucleusShellInput

/// The shell's Wayland-to-NucleusUI input translation.
///
/// The evdev codes and Wayland state live on one side of this boundary and the
/// framework's platform-neutral vocabulary on the other; these pin the mapping
/// between them.
@MainActor
@Suite struct ShellInputRouterTests {
    private func pointerEvent(
        _ kind: ShellInputEventKind, x: Double = 0, y: Double = 0, button: UInt32 = 272
    ) -> ShellInputEvent {
        var event = ShellInputEvent(kind: kind)
        event.x = x
        event.y = y
        event.button = button
        return event
    }

    private func keyEvent(
        _ kind: ShellInputEventKind = .keyDown,
        keycode: UInt32,
        text: String? = nil,
        isRepeat: Bool = false,
        modifiers: ShellModifierState = ShellModifierState()
    ) -> ShellInputEvent {
        var event = ShellInputEvent(kind: kind)
        event.keycode = keycode
        event.text = text
        event.isRepeat = isRepeat
        event.modifiers = modifiers
        return event
    }

    private func translate(_ event: ShellInputEvent) -> Event? {
        ShellInputRouter.nucleonEvent(event, lastLocation: Point(x: 0, y: 0))
    }

    // MARK: - Pointer

    @Test func pointerMotionBecomesAMoveAtTheSameLocation() throws {
        let event = try #require(translate(pointerEvent(.pointerMotion, x: 12, y: 34)))
        #expect(event.type == .pointerMoved)
        #expect(event.location == Point(x: 12, y: 34))
    }

    @Test func evdevButtonsMapOntoTheNamedButtons() {
        #expect(ShellInputRouter.pointerButton(272) == .left)
        #expect(ShellInputRouter.pointerButton(273) == .right)
        #expect(ShellInputRouter.pointerButton(274) == .middle)
        #expect(ShellInputRouter.pointerButton(275) == .back)
        #expect(ShellInputRouter.pointerButton(276) == .forward)
    }

    /// An unknown button keeps its raw code rather than collapsing onto `.left`,
    /// which would make a stray device press look like a click.
    @Test func anUnknownButtonKeepsItsRawCode() {
        #expect(ShellInputRouter.pointerButton(999) == PointerButton(rawValue: 999))
    }

    @Test func aButtonPressBecomesAPointerDownWithAClickCount() throws {
        let event = try #require(
            translate(pointerEvent(.pointerButtonDown, x: 5, y: 6, button: 273)))
        #expect(event.type == .pointerDown)
        #expect(event.button == .right)
        #expect(event.clickCount == 1)
        #expect(event.location == Point(x: 5, y: 6))
    }

    @Test func axisEventsCarryTheirDeltasAndPrecisionFlag() throws {
        var wayland = pointerEvent(.pointerAxis)
        wayland.scrollY = -3.5
        wayland.hasPreciseScrolling = true

        let event = try #require(translate(wayland))
        #expect(event.type == .scrollWheel)
        #expect(event.scrollDeltaY == -3.5)
        #expect(event.hasPreciseScrollingDeltas)
    }

    // MARK: - Keyboard

    @Test func evdevKeyCodesMapOntoTheNeutralSpace() {
        #expect(ShellInputRouter.keyCode(1) == .escape)
        #expect(ShellInputRouter.keyCode(14) == .delete)
        #expect(ShellInputRouter.keyCode(15) == .tab)
        #expect(ShellInputRouter.keyCode(28) == .return)
        #expect(ShellInputRouter.keyCode(96) == .return, "keypad enter is still Return")
        #expect(ShellInputRouter.keyCode(57) == .space)
        #expect(ShellInputRouter.keyCode(103) == .upArrow)
        #expect(ShellInputRouter.keyCode(105) == .leftArrow)
        #expect(ShellInputRouter.keyCode(106) == .rightArrow)
        #expect(ShellInputRouter.keyCode(108) == .downArrow)
        #expect(ShellInputRouter.keyCode(111) == .forwardDelete)
    }

    /// Composed text rides alongside the keycode. This is the whole reason the
    /// shell compiles the keymap it is handed: a keycode cannot say what a
    /// layout, dead key, or compose sequence produced.
    @Test func composedTextBecomesTheEventsCharacters() throws {
        let event = try #require(translate(keyEvent(keycode: 30, text: "ä")))
        #expect(event.type == .keyDown)
        #expect(event.characters == "ä")
    }

    @Test func aKeyWithNoTextCarriesNone() throws {
        let event = try #require(translate(keyEvent(keycode: 105)))
        #expect(event.keyCode == .leftArrow)
        #expect(event.characters == nil)
    }

    @Test func repeatsAreMarkedAsSuch() throws {
        let event = try #require(translate(keyEvent(keycode: 105, isRepeat: true)))
        #expect(event.isARepeat)
        #expect(!(try #require(translate(keyEvent(keycode: 105)))).isARepeat)
    }

    @Test func modifierStateBecomesFrameworkFlags() {
        var state = ShellModifierState()
        state.shift = true
        state.logo = true
        let flags = ShellInputRouter.modifierFlags(state)

        #expect(flags.contains(.shift))
        #expect(flags.contains(.command), "the logo key is the command modifier")
        #expect(!flags.contains(.control))
    }

    @Test func everyModifierIsMapped() {
        var state = ShellModifierState()
        state.shift = true
        state.control = true
        state.alt = true
        state.logo = true
        state.capsLock = true
        let flags = ShellInputRouter.modifierFlags(state)

        #expect(flags.contains(.shift))
        #expect(flags.contains(.control))
        #expect(flags.contains(.option))
        #expect(flags.contains(.command))
        #expect(flags.contains(.capsLock))
    }

    /// A key event has no pointer position of its own, so it carries the last
    /// one — a view reading `location` on a key event must not see the origin.
    @Test func keyEventsCarryTheLastPointerLocation() throws {
        let event = try #require(
            ShellInputRouter.nucleonEvent(keyEvent(keycode: 30), lastLocation: Point(x: 9, y: 4)))
        #expect(event.location == Point(x: 9, y: 4))
    }

    /// Focus transitions are scene state, not events to dispatch.
    @Test func focusTransitionsProduceNoEvent() {
        #expect(translate(ShellInputEvent(kind: .keyboardEnter)) == nil)
        #expect(translate(ShellInputEvent(kind: .keyboardLeave)) == nil)
        #expect(translate(ShellInputEvent(kind: .pointerLeave)) == nil)
    }

    // MARK: - Scene routing

    private final class RecordingView: View {
        var received: [EventType] = []
        override var acceptsFirstResponder: Bool { true }
        override func handleEvent(_ event: Event) -> EventHandling {
            received.append(event.type)
            return .handled
        }
    }

    /// Keyboard focus arriving at a surface makes its window key. Without it no
    /// first responder would ever receive a key.
    @Test func keyboardEnterMakesTheSurfacesWindowKey() {
        let scene = WindowScene(windows: [])
        let window = Window(title: "Bar")
        let view = RecordingView()
        view.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        window.setContentView(view)
        window.orderFront()
        scene.addWindow(window)

        // Real seats come from a live Wayland connection, so drive the router's
        // delegate path directly rather than binding one.
        let router = ShellInputRouter(scene: scene, seat: nil)
        router.register(window: window, forSurface: 42)

        var enter = ShellInputEvent(kind: .keyboardEnter)
        enter.surface = 42
        router.deliver(enter)
        #expect(scene.keyWindow === window)

        router.deliver(ShellInputEvent(kind: .keyboardLeave))
        #expect(scene.keyWindow == nil, "focus genuinely left")

        withExtendedLifetime(window) {}
    }

    /// Events for a surface the router does not own are ignored rather than
    /// misrouted onto whatever window happens to be first.
    @Test func anUnknownSurfaceIsIgnored() {
        let scene = WindowScene(windows: [])
        let window = Window(title: "Bar")
        let view = RecordingView()
        view.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        window.setContentView(view)
        window.orderFront()
        scene.addWindow(window)

        let router = ShellInputRouter(scene: scene, seat: nil)
        router.register(window: window, forSurface: 42)

        var enter = ShellInputEvent(kind: .keyboardEnter)
        enter.surface = 7
        router.deliver(enter)
        #expect(scene.keyWindow == nil)

        withExtendedLifetime(window) {}
    }

    @Test func pointerEventsReachAViewThroughTheScene() {
        let scene = WindowScene(windows: [])
        let window = Window(title: "Bar")
        let view = RecordingView()
        view.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        window.setContentView(view)
        window.orderFront()
        scene.addWindow(window)

        let router = ShellInputRouter(scene: scene, seat: nil)
        router.register(window: window, forSurface: 42)
        router.deliver(pointerEvent(.pointerButtonDown, x: 10, y: 10))

        #expect(view.received.contains(.pointerDown))
        withExtendedLifetime(window) {}
    }
}
