import NucleusShellWayland
import NucleusUI

/// Translates the shell's Wayland input records into NucleusUI events and
/// dispatches them into a scene.
///
/// The shell's counterpart to the compositor's overlay adapter, and the same
/// tier split: `NucleusShellWayland` speaks evdev and knows nothing about the UI
/// framework, `NucleusUI` speaks platform-neutral codes and knows nothing about
/// Wayland, and this type is the only place the two vocabularies meet.
@MainActor
public final class ShellInputRouter: ShellSeatDelegate {
    public var onSurfaceWillUnregister:
        (@MainActor (_ surfaceID: UInt) -> Void)?
    private let scene: WindowScene
    /// Optional so the router can exist before — or without — a live seat. A
    /// seat comes from a real Wayland connection; the translation and routing do
    /// not depend on having one.
    private var seat: ShellSeat?
    private var textInput: ShellTextInput?
    /// Surfaces the router owns, mapped to the window each one presents. Events
    /// for anything else are ignored rather than misrouted.
    private var windowsBySurface: [UInt: Window] = [:]

    /// The most recent pointer position, so a button event — which carries no
    /// coordinates of its own in `wl_pointer` — lands where the pointer is.
    private var pointerLocation = Point(x: 0, y: 0)

    public init(
        scene: WindowScene,
        seat: ShellSeat?,
        client: ShellWaylandClient? = nil
    ) {
        self.scene = scene
        self.seat = seat
        if let seat, let client {
            self.textInput = ShellTextInput(
                client: client,
                seat: seat.protocolSeat
            )
        } else {
            self.textInput = nil
        }
        seat?.delegate = self
    }

    /// Rebind seat-scoped input protocols after registry replacement while
    /// preserving the scene and every surface-to-window association.
    public func replaceSeat(
        _ replacement: ShellSeat?,
        client: ShellWaylandClient
    ) {
        seat?.delegate = nil
        textInput?.close()
        seat = replacement
        textInput = replacement.flatMap {
            ShellTextInput(client: client, seat: $0.protocolSeat)
        }
        replacement?.delegate = self
        for window in windowsBySurface.values {
            window.installTextInputAdapter(textInput)
        }
    }

    /// Associate a `wl_surface` with the window that draws it.
    public func register(window: Window, forSurface surfaceID: UInt) {
        if let replaced = windowsBySurface[surfaceID], replaced !== window {
            replaced.installTextInputAdapter(nil)
            replaced.setSurfaceAssociation(nil)
        }
        windowsBySurface[surfaceID] = window
        window.installTextInputAdapter(textInput)
        if surfaceID != 0 {
            window.setSurfaceAssociation(WindowSurfaceAssociation(
                surfaceID: PresentationSurfaceID(rawValue: UInt64(surfaceID))
            ))
        }
    }

    public func unregister(surfaceID: UInt) {
        onSurfaceWillUnregister?(surfaceID)
        let window = windowsBySurface.removeValue(forKey: surfaceID)
        window?.installTextInputAdapter(nil)
        if window?.surfaceAssociation?.surfaceID.rawValue == UInt64(surfaceID) {
            window?.setSurfaceAssociation(nil)
        }
    }

    /// Resolve one Wayland surface-local drag coordinate into the retained
    /// scene. Unknown or detached surfaces are rejected at this boundary.
    public func dragDestination(
        forSurface surfaceID: UInt,
        location: Point
    ) -> (scene: WindowScene, sceneLocation: Point)? {
        guard windowsBySurface[surfaceID]?.windowScene === scene else {
            return nil
        }
        return (
            scene,
            rebased(location, forSurface: surfaceID))
    }

    /// Emit any key repeats now due. Driven from the host's event loop, which
    /// folds `nanosecondsUntilNextRepeat` into its poll timeout so repeats are
    /// not quantized to the frame rate.
    public func advanceKeyRepeat(nowNs: UInt64) {
        seat?.advanceKeyRepeat(nowNs: nowNs)
    }

    public func nanosecondsUntilNextRepeat(nowNs: UInt64) -> UInt64? {
        seat?.nanosecondsUntilNextRepeat(nowNs: nowNs)
    }

    // MARK: - ShellSeatDelegate

    public func seat(_ seat: ShellSeat, didProduce event: ShellInputEvent) {
        deliver(event)
    }

    /// Route one input record. The delegate callback funnels here, and so does
    /// anything driving the router without a live seat.
    public func deliver(_ event: ShellInputEvent) {
        switch event.kind {
        case .keyboardEnter:
            // Keyboard focus arriving at a surface makes its window the key
            // window; without this no first responder would ever receive keys.
            if let window = windowsBySurface[event.surface] {
                scene.makeKey(window)
            }
        case .keyboardLeave:
            scene.resignKey()
        case .pointerLeave:
            scene.cancelInputSequences()
            // Nothing is under the pointer any more, so any tracked view must be
            // told it was exited.
            _ = scene.dispatchEvent(Event(
                type: .pointerExited,
                location: pointerLocation,
                timestampNanoseconds: event.timestampNanoseconds))
        default:
            guard var nucleon = ShellInputRouter.nucleonEvent(
                event, lastLocation: pointerLocation) else { return }
            if nucleon.isPointerEvent {
                // Wayland reports pointer positions surface-local, but the scene
                // hit-tests in its own logical space, where a window may sit at
                // any origin — the shell places its surfaces in disjoint regions
                // so they do not composite on top of each other. Rebase, or every
                // hit test misses by the window's origin.
                nucleon.location = rebased(nucleon.location, forSurface: event.surface)
                pointerLocation = nucleon.location
            }
            _ = scene.dispatchEvent(nucleon)
        }
    }

    /// Surface-local to scene-logical, using the registered window's origin.
    /// An unregistered surface is left alone: there is no window to rebase onto.
    private func rebased(_ location: Point, forSurface surfaceID: UInt) -> Point {
        guard let window = windowsBySurface[surfaceID] else { return location }
        let inWindow = window.surfaceAssociation?.transform.windowPoint(
            fromSurface: location
        ) ?? location
        return scene.scenePoint(inWindow, in: window)
    }

    // MARK: - Translation

    /// Map one Wayland record onto a framework event, or `nil` when it carries
    /// nothing the framework models.
    static func nucleonEvent(
        _ event: ShellInputEvent, lastLocation: Point
    ) -> Event? {
        let modifiers = modifierFlags(event.modifiers)
        // Button events carry no coordinates of their own in `wl_pointer`; the
        // seat fills in the last motion position before emitting, so this is
        // already correct for every pointer kind.
        let location = Point(x: event.x, y: event.y)

        switch event.kind {
        case .pointerEnter:
            return Event(
                type: .pointerEntered, modifierFlags: modifiers, location: location,
                timestampNanoseconds: event.timestampNanoseconds)
        case .pointerMotion:
            return Event(
                type: event.activeButtonCodes.isEmpty
                    ? .pointerMoved
                    : .pointerDragged,
                modifierFlags: modifiers,
                location: location,
                timestampNanoseconds: event.timestampNanoseconds,
                activeButtons: pointerButtonMask(event.activeButtonCodes),
                pointerTool: .mouse)
        case .pointerButtonDown:
            return Event(
                type: .pointerDown, modifierFlags: modifiers, location: location,
                timestampNanoseconds: event.timestampNanoseconds,
                button: pointerButton(event.button),
                activeButtons: pointerButtonMask(event.activeButtonCodes),
                pointerTool: .mouse,
                clickCount: 1)
        case .pointerButtonUp:
            return Event(
                type: .pointerUp, modifierFlags: modifiers, location: location,
                timestampNanoseconds: event.timestampNanoseconds,
                button: pointerButton(event.button),
                activeButtons: pointerButtonMask(event.activeButtonCodes),
                pointerTool: .mouse,
                clickCount: 1)
        case .pointerAxis:
            return Event(
                type: .scrollWheel, modifierFlags: modifiers, location: location,
                timestampNanoseconds: event.timestampNanoseconds,
                scrollDeltaX: event.scrollX, scrollDeltaY: event.scrollY,
                scrollSource: scrollSource(event.scrollSource),
                scrollDetentsX: event.scrollDetentsX,
                scrollDetentsY: event.scrollDetentsY,
                scrollPhase: event.scrollEnded ? .ended : .changed)
        case .keyDown, .keyUp:
            return Event(
                type: event.kind == .keyDown ? .keyDown : .keyUp,
                modifierFlags: modifiers,
                location: lastLocation,
                timestampNanoseconds: event.timestampNanoseconds,
                keyCode: keyCode(event.keycode),
                characters: event.text,
                isARepeat: event.isRepeat)
        case .pointerLeave, .keyboardEnter, .keyboardLeave:
            return nil
        }
    }

    static func modifierFlags(_ state: ShellModifierState) -> EventModifierFlags {
        var flags: EventModifierFlags = []
        if state.shift { flags.insert(.shift) }
        if state.control { flags.insert(.control) }
        if state.alt { flags.insert(.option) }
        if state.logo { flags.insert(.command) }
        if state.capsLock { flags.insert(.capsLock) }
        return flags
    }

    /// evdev button codes. `BTN_LEFT` is 272 and the rest follow it.
    static func pointerButton(_ code: UInt32) -> PointerButton {
        switch code {
        case 272: return .left
        case 273: return .right
        case 274: return .middle
        case 275: return .back
        case 276: return .forward
        default: return PointerButton(rawValue: code)
        }
    }

    static func pointerButtonMask(
        _ codes: Set<UInt32>
    ) -> PointerButtonMask {
        codes.reduce(into: PointerButtonMask()) { result, code in
            result.formUnion(.button(pointerButton(code)))
        }
    }

    /// evdev key codes onto the framework's own key space.
    ///
    /// The table lives in `KeyCode(linuxEvdevCode:)`. It used to be duplicated
    /// here and in the compositor's overlay adapter, on the reasoning that
    /// `core/` should not adopt a platform's numbering — but the duplication is
    /// what broke it: both copies passed unmapped codes through as raw values,
    /// which collided with the low-numbered named constants. Naming the platform
    /// in the API keeps the numbering framework-owned while there is only one
    /// copy of the mapping.
    static func keyCode(_ code: UInt32) -> KeyCode {
        KeyCode(linuxEvdevCode: code)
    }

    /// `wl_pointer.axis_source` onto the framework's own vocabulary.
    static func scrollSource(_ source: UInt32) -> ScrollSource {
        switch source {
        case 0: .wheel
        case 1: .finger
        case 2: .continuous
        case 3: .wheelTilt
        default: .unknown
        }
    }
}
