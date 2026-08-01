package import NucleusLayers
import NucleusTypes
import NucleusUI
import NucleusUIEmbedder
import NucleusUITestSupport
import NucleusWindowClientWayland
import Testing

import struct NucleusUI.Point

@testable import NucleusWindowClientInput

/// The shell's Wayland-to-NucleusUI input translation.
///
/// The evdev codes and Wayland state live on one side of this boundary and the
/// framework's platform-neutral vocabulary on the other; these pin the mapping
/// between them.
@MainActor
@Suite(.uiContext) struct NucleusDesktopInputRouterTests {
    private func pointerEvent(
        _ kind: InputEventKind,
        x: Double = 0,
        y: Double = 0,
        button: PointerButtonCode = .left
    ) -> ApplicationInputEvent {
        var event = ApplicationInputEvent(kind: kind)
        event.location = NucleusTypes.Point(x: x, y: y)
        event.button = button
        return event
    }

    private func keyEvent(
        _ kind: InputEventKind = .keyDown,
        keycode: UInt32,
        text: String? = nil,
        isRepeat: Bool = false,
        modifiers: InputModifierFlags = []
    ) -> ApplicationInputEvent {
        var event = ApplicationInputEvent(kind: kind)
        event.key = PhysicalKey(linuxEvdevCode: keycode)
        event.text = text
        event.isRepeat = isRepeat
        event.modifiers = modifiers
        return event
    }

    private func translate(_ event: ApplicationInputEvent) -> Event? {
        NucleusDesktopInputRouter.nucleonEvent(
            event,
            lastLocation: Point(x: 0, y: 0))
    }

    // MARK: - Pointer

    @Test func pointerMotionBecomesAMoveAtTheSameLocation() throws {
        let event = try #require(translate(pointerEvent(.pointerMotion, x: 12, y: 34)))
        #expect(event.type == .pointerMoved)
        #expect(event.location == Point(x: 12, y: 34))
    }

    @Test func pointerMotionWithPressedButtonsBecomesADrag() throws {
        var wayland = pointerEvent(.pointerMotion, x: 12, y: 34)
        wayland.activeButtons = [
            .button(.left),
            .button(.middle),
        ]
        let event = try #require(translate(wayland))
        #expect(event.type == .pointerDragged)
        #expect(event.activeButtons == [.left, .middle])
        #expect(event.pointerTool == .mouse)
    }

    @Test func evdevButtonsMapOntoTheNamedButtons() {
        #expect(NucleusDesktopInputRouter.pointerButton(.left) == .left)
        #expect(NucleusDesktopInputRouter.pointerButton(.right) == .right)
        #expect(NucleusDesktopInputRouter.pointerButton(.middle) == .middle)
        #expect(NucleusDesktopInputRouter.pointerButton(.back) == .back)
        #expect(NucleusDesktopInputRouter.pointerButton(.forward) == .forward)
    }

    /// An unknown button keeps its raw code rather than collapsing onto `.left`,
    /// which would make a stray device press look like a click.
    @Test func anUnknownButtonKeepsItsRawCode() {
        #expect(
            NucleusDesktopInputRouter.pointerButton(
                PointerButtonCode(rawValue: 999)
            ) == PointerButton(rawValue: 999))
    }

    @Test func aButtonPressBecomesAPointerDownWithAClickCount() throws {
        let event = try #require(
            translate(pointerEvent(.pointerButtonDown, x: 5, y: 6, button: .right)))
        #expect(event.type == .pointerDown)
        #expect(event.button == .right)
        #expect(event.clickCount == 1)
        #expect(event.location == Point(x: 5, y: 6))
    }

    @Test func axisEventsCarryTheirDeltasAndSource() throws {
        var wayland = pointerEvent(.pointerAxis)
        wayland.scrollY = -3.5
        wayland.scrollSource = .finger

        let event = try #require(translate(wayland))
        #expect(event.type == .scrollWheel)
        #expect(event.scrollDeltaY == -3.5)
        #expect(event.scrollSource == .finger)
        #expect(event.hasPreciseScrollingDeltas)
    }

    /// High-resolution wheel travel arrives on `axis_value120` and nowhere else,
    /// so a free-spinning wheel's sub-notch movement depends on it surviving
    /// translation.
    @Test func axisEventsCarryTheirDetents() throws {
        var wayland = pointerEvent(.pointerAxis)
        wayland.scrollSource = .wheel
        wayland.scrollDetentsY = 0.25

        let event = try #require(translate(wayland))
        #expect(event.scrollDetentsY == 0.25)
        #expect(event.scrollSource == .wheel)
        #expect(!event.hasPreciseScrollingDeltas)
    }

    /// `axis_stop` is the end of a gesture. There is no momentum phase behind
    /// it — the compositor synthesizes no inertia — so a view that wants
    /// kinetic scrolling starts it here.
    @Test func axisStopMarksTheEndOfAGesture() throws {
        var wayland = pointerEvent(.pointerAxis)
        wayland.scrollPhase = .ended

        let event = try #require(translate(wayland))
        #expect(event.scrollPhase == .ended)
    }

    @Test func everyAxisSourceMaps() {
        #expect(NucleusDesktopInputRouter.scrollSource(.wheel) == .wheel)
        #expect(NucleusDesktopInputRouter.scrollSource(.finger) == .finger)
        #expect(NucleusDesktopInputRouter.scrollSource(.continuous) == .continuous)
        #expect(NucleusDesktopInputRouter.scrollSource(.wheelTilt) == .wheelTilt)
        #expect(NucleusDesktopInputRouter.scrollSource(.unknown) == .unknown)
    }

    // MARK: - Keyboard

    @Test func evdevKeyCodesMapOntoTheNeutralSpace() {
        #expect(PhysicalKey(linuxEvdevCode: 1) == .escape)
        #expect(PhysicalKey(linuxEvdevCode: 14) == .delete)
        #expect(PhysicalKey(linuxEvdevCode: 15) == .tab)
        #expect(PhysicalKey(linuxEvdevCode: 28) == .return)
        #expect(PhysicalKey(linuxEvdevCode: 96) == .return, "keypad enter is still Return")
        #expect(PhysicalKey(linuxEvdevCode: 57) == .space)
        #expect(PhysicalKey(linuxEvdevCode: 103) == .upArrow)
        #expect(PhysicalKey(linuxEvdevCode: 105) == .leftArrow)
        #expect(PhysicalKey(linuxEvdevCode: 106) == .rightArrow)
        #expect(PhysicalKey(linuxEvdevCode: 108) == .downArrow)
        #expect(PhysicalKey(linuxEvdevCode: 111) == .forwardDelete)
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
        let state: InputModifierFlags = [.shift, .command]
        let flags = NucleusDesktopInputRouter.modifierFlags(state)

        #expect(flags.contains(.shift))
        #expect(flags.contains(.command), "the logo key is the command modifier")
        #expect(!flags.contains(.control))
    }

    @Test func everyModifierIsMapped() {
        let state: InputModifierFlags = [
            .shift,
            .control,
            .option,
            .command,
            .capsLock,
        ]
        let flags = NucleusDesktopInputRouter.modifierFlags(state)

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
            NucleusDesktopInputRouter.nucleonEvent(
                keyEvent(keycode: 30),
                lastLocation: Point(x: 9, y: 4)))
        #expect(event.location == Point(x: 9, y: 4))
    }

    /// Focus transitions are scene state, not events to dispatch.
    @Test func focusTransitionsProduceNoEvent() {
        #expect(translate(ApplicationInputEvent(kind: .keyboardEnter)) == nil)
        #expect(translate(ApplicationInputEvent(kind: .keyboardLeave)) == nil)
        #expect(translate(ApplicationInputEvent(kind: .pointerLeave)) == nil)
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
        let scene = WindowScene(inMemoryWindows: [])
        let (window, _) = scene.uiContext.construct {
            let window = Window(title: "Bar")
            let view = RecordingView()
            view.frame = Rect(x: 0, y: 0, width: 100, height: 40)
            window.setContentView(view)
            window.orderFront()
            return (window, view)
        }
        scene.addWindow(window)

        // Real seats come from a live Wayland connection, so drive the router's
        // delegate path directly rather than binding one.
        let router = NucleusDesktopInputRouter(scene: scene, seat: nil)
        router.register(window: window, forSurface: 42)

        var enter = ApplicationInputEvent(kind: .keyboardEnter)
        enter.surfaceID = SurfaceID(rawValue: 42)
        router.deliver(enter)
        #expect(scene.keyWindow === window)

        router.deliver(ApplicationInputEvent(kind: .keyboardLeave))
        #expect(scene.keyWindow == nil, "focus genuinely left")

        withExtendedLifetime(window) {}
    }

    /// Events for a surface the router does not own are ignored rather than
    /// misrouted onto whatever window happens to be first.
    @Test func anUnknownSurfaceIsIgnored() {
        let scene = WindowScene(inMemoryWindows: [])
        let (window, _) = scene.uiContext.construct {
            let window = Window(title: "Bar")
            let view = RecordingView()
            view.frame = Rect(x: 0, y: 0, width: 100, height: 40)
            window.setContentView(view)
            window.orderFront()
            return (window, view)
        }
        scene.addWindow(window)

        let router = NucleusDesktopInputRouter(scene: scene, seat: nil)
        router.register(window: window, forSurface: 42)

        var enter = ApplicationInputEvent(kind: .keyboardEnter)
        enter.surfaceID = SurfaceID(rawValue: 7)
        router.deliver(enter)
        #expect(scene.keyWindow == nil)

        withExtendedLifetime(window) {}
    }

    /// A window away from the scene's origin still hit-tests correctly. Wayland
    /// reports pointer positions surface-local; the shell places surfaces in
    /// disjoint logical regions so they do not composite over each other, so
    /// without rebasing every hit test misses by the window's origin. This is
    /// exactly the lock screen's situation.
    @Test func pointerEventsRebaseOntoAWindowAwayFromTheOrigin() {
        let scene = WindowScene(inMemoryWindows: [])
        let (window, view) = scene.uiContext.construct {
            let window = Window(title: "Lock")
            let view = RecordingView()
            view.frame = Rect(x: 0, y: 0, width: 800, height: 600)
            window.setContentView(view)
            window.setFrame(Rect(x: 0, y: 1_000_000, width: 800, height: 600))
            window.orderFront()
            return (window, view)
        }
        scene.addWindow(window)

        let router = NucleusDesktopInputRouter(scene: scene, seat: nil)
        router.register(window: window, forSurface: 42)

        // Surface-local (10, 10) — near the window's top-left, a million points
        // down in scene space.
        var press = ApplicationInputEvent(kind: .pointerButtonDown)
        press.surfaceID = SurfaceID(rawValue: 42)
        press.button = .left
        press.location = NucleusTypes.Point(x: 10, y: 10)
        router.deliver(press)

        #expect(view.received.contains(.pointerDown), "the press found the window")
        withExtendedLifetime(window) {}
    }

    /// An unregistered surface is left alone rather than rebased onto some other
    /// window's origin.
    @Test func anUnregisteredSurfacesPointerIsNotRebased() {
        let scene = WindowScene(inMemoryWindows: [])
        let (window, view) = scene.uiContext.construct {
            let window = Window(title: "Lock")
            let view = RecordingView()
            view.frame = Rect(x: 0, y: 0, width: 800, height: 600)
            window.setContentView(view)
            window.setFrame(Rect(x: 0, y: 1_000_000, width: 800, height: 600))
            window.orderFront()
            return (window, view)
        }
        scene.addWindow(window)

        let router = NucleusDesktopInputRouter(scene: scene, seat: nil)
        router.register(window: window, forSurface: 42)

        var press = ApplicationInputEvent(kind: .pointerButtonDown)
        press.surfaceID = SurfaceID(rawValue: 99)
        press.button = .left
        press.location = NucleusTypes.Point(x: 10, y: 10)
        router.deliver(press)

        #expect(!view.received.contains(.pointerDown))
        withExtendedLifetime(window) {}
    }

    @Test func pointerEventsReachAViewThroughTheScene() {
        let scene = WindowScene(inMemoryWindows: [])
        let (window, view) = scene.uiContext.construct {
            let window = Window(title: "Bar")
            let view = RecordingView()
            view.frame = Rect(x: 0, y: 0, width: 100, height: 40)
            window.setContentView(view)
            window.orderFront()
            return (window, view)
        }
        scene.addWindow(window)

        let router = NucleusDesktopInputRouter(scene: scene, seat: nil)
        router.register(window: window, forSurface: 42)
        router.deliver(pointerEvent(.pointerButtonDown, x: 10, y: 10))

        #expect(view.received.contains(.pointerDown))
        withExtendedLifetime(window) {}
    }

    @Test func waylandClientAdapterPublishesMutatesAndTearsDownOneScene()
        throws
    {
        let sink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 8_701),
            commitSink: sink,
            services: .inMemory())
        let (window, view) = publication.withSemanticContext {
            let window = Window(title: "Wayland client")
            let view = RecordingView()
            view.frame = Rect(x: 0, y: 0, width: 100, height: 40)
            view.backgroundColor = Color(0.2, 0.3, 0.4, 1)
            window.setContentView(view)
            window.orderFront()
            return (window, view)
        }
        let scene = publication.makeWindowScene(windows: [window])
        let router = NucleusDesktopInputRouter(scene: scene, seat: nil)
        router.register(window: window, forSurface: 42)

        _ = try scene.publish()
        let firstLayerCount = publication.visualContext.layers.count
        #expect(firstLayerCount >= 2)
        var press = pointerEvent(.pointerButtonDown, x: 10, y: 10)
        press.surfaceID = SurfaceID(rawValue: 42)
        router.deliver(press)
        #expect(view.received.contains(.pointerDown))

        view.alphaValue = 0.5
        _ = try scene.publish()
        #expect(
            sink.transactions.last?.propertyUpdates.contains {
                $0.properties.opacity == 0.5
            } == true)

        router.unregister(surfaceID: 42)
        try scene.disconnect()
        #expect(scene.windows.isEmpty)
        #expect(publication.visualContext.layers.isEmpty)
        #expect(sink.transactions.last?.removed.isEmpty == false)
    }
}
