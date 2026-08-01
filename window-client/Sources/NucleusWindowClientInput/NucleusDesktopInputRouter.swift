package import NucleusAppHostProtocols
import NucleusTypes
package import NucleusUI
package import NucleusWindowClientWayland

import struct NucleusUI.Point

/// Adapts role-neutral application input into NucleusUI events and dispatches
/// them into a scene.
///
/// `NucleusWindowClientWayland` resolves native Wayland/evdev values without importing
/// the UI framework. This desktop adapter is the only layer that knows the
/// NucleusUI responder model.
@MainActor
package final class NucleusDesktopInputRouter: NucleusDesktopSeatDelegate, ApplicationEventSink {
    package var onSurfaceWillUnregister: (@MainActor (_ surfaceID: UInt) -> Void)?
    private let scene: WindowScene
    /// Optional so the router can exist before — or without — a live seat. A
    /// seat comes from a real Wayland connection; the translation and routing do
    /// not depend on having one.
    private var seat: NucleusDesktopSeat?
    private var textInput: NucleusDesktopTextInput?
    /// Surfaces the router owns, mapped to the window each one presents. Events
    /// for anything else are ignored rather than misrouted.
    private var windowsBySurface: [UInt: Window] = [:]

    /// The most recent pointer position, so a button event — which carries no
    /// coordinates of its own in `wl_pointer` — lands where the pointer is.
    private var pointerLocation = Point(x: 0, y: 0)

    package init(
        scene: WindowScene,
        seat: NucleusDesktopSeat?,
        client: NucleusDesktopConnection? = nil
    ) {
        self.scene = scene
        self.seat = seat
        if let seat, let client {
            self.textInput = NucleusDesktopTextInput(
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
    package func replaceSeat(
        _ replacement: NucleusDesktopSeat?,
        client: NucleusDesktopConnection
    ) {
        seat?.delegate = nil
        textInput?.close()
        seat = replacement
        textInput = replacement.flatMap {
            NucleusDesktopTextInput(client: client, seat: $0.protocolSeat)
        }
        replacement?.delegate = self
        for window in windowsBySurface.values {
            window.installTextInputAdapter(textInput)
        }
    }

    /// Associate a `wl_surface` with the window that draws it.
    package func register(window: Window, forSurface surfaceID: UInt) {
        if let replaced = windowsBySurface[surfaceID], replaced !== window {
            replaced.installTextInputAdapter(nil)
            replaced.setSurfaceAssociation(nil)
        }
        windowsBySurface[surfaceID] = window
        window.installTextInputAdapter(textInput)
        if surfaceID != 0 {
            window.setSurfaceAssociation(
                WindowSurfaceAssociation(
                    surfaceID: PresentationSurfaceID(rawValue: UInt64(surfaceID))
                ))
        }
    }

    package func unregister(surfaceID: UInt) {
        onSurfaceWillUnregister?(surfaceID)
        let window = windowsBySurface.removeValue(forKey: surfaceID)
        window?.installTextInputAdapter(nil)
        if window?.surfaceAssociation?.surfaceID.rawValue == UInt64(surfaceID) {
            window?.setSurfaceAssociation(nil)
        }
    }

    /// Resolve one Wayland surface-local drag coordinate into the retained
    /// scene. Unknown or detached surfaces are rejected at this boundary.
    package func dragDestination(
        forSurface surfaceID: UInt,
        location: Point
    ) -> (scene: WindowScene, sceneLocation: Point)? {
        guard windowsBySurface[surfaceID]?.windowScene === scene else {
            return nil
        }
        return (
            scene,
            rebased(location, forSurface: surfaceID)
        )
    }

    /// Emit any key repeats now due. Driven from the host's event loop, which
    /// folds `nanosecondsUntilNextRepeat` into its poll timeout so repeats are
    /// not quantized to the frame rate.
    package func advanceKeyRepeat(nowNs: UInt64) {
        seat?.advanceKeyRepeat(nowNs: nowNs)
    }

    package func nanosecondsUntilNextRepeat(nowNs: UInt64) -> UInt64? {
        seat?.nanosecondsUntilNextRepeat(nowNs: nowNs)
    }

    // MARK: - NucleusDesktopSeatDelegate

    package func seat(_ seat: NucleusDesktopSeat, didProduce event: ApplicationInputEvent) {
        receive(event)
    }

    package func receive(_ event: ApplicationInputEvent) {
        deliver(event)
    }

    /// Route one input record. The delegate callback funnels here, and so does
    /// anything driving the router without a live seat.
    package func deliver(_ event: ApplicationInputEvent) {
        let surfaceID = UInt(event.surfaceID?.rawValue ?? 0)
        switch event.kind {
        case .keyboardEnter:
            // Keyboard focus arriving at a surface makes its window the key
            // window; without this no first responder would ever receive keys.
            if let window = windowsBySurface[surfaceID] {
                scene.makeKey(window)
            }
        case .keyboardLeave:
            scene.resignKey()
        case .pointerLeave:
            scene.cancelInputSequences()
            // Nothing is under the pointer any more, so any tracked view must be
            // told it was exited.
            _ = scene.dispatchEvent(
                Event(
                    type: .pointerExited,
                    location: pointerLocation,
                    timestampNanoseconds: event.timestampNanoseconds))
        default:
            guard
                var nucleon = NucleusDesktopInputRouter.nucleonEvent(
                    event, lastLocation: pointerLocation)
            else { return }
            if nucleon.isPointerEvent {
                // Wayland reports pointer positions surface-local, but the scene
                // hit-tests in its own logical space, where a window may sit at
                // any origin — the desktop host places its surfaces in disjoint regions
                // so they do not composite on top of each other. Rebase, or every
                // hit test misses by the window's origin.
                nucleon.location = rebased(nucleon.location, forSurface: surfaceID)
                pointerLocation = nucleon.location
            }
            _ = scene.dispatchEvent(nucleon)
        }
    }

    /// Surface-local to scene-logical, using the registered window's origin.
    /// An unregistered surface is left alone: there is no window to rebase onto.
    private func rebased(
        _ location: Point,
        forSurface surfaceID: UInt
    ) -> Point {
        guard let window = windowsBySurface[surfaceID] else { return location }
        let inWindow =
            window.surfaceAssociation?.transform.windowPoint(
                fromSurface: location
            ) ?? location
        return scene.scenePoint(inWindow, in: window)
    }

    // MARK: - Translation

    /// Map one Wayland record onto a framework event, or `nil` when it carries
    /// nothing the framework models.
    static func nucleonEvent(
        _ event: ApplicationInputEvent, lastLocation: Point
    ) -> Event? {
        let modifiers = modifierFlags(event.modifiers)
        // Button events carry no coordinates of their own in `wl_pointer`; the
        // seat fills in the last motion position before emitting, so this is
        // already correct for every pointer kind.
        let location = Point(
            x: event.location.x,
            y: event.location.y)

        switch event.kind {
        case .pointerEnter:
            return Event(
                type: .pointerEntered, modifierFlags: modifiers, location: location,
                timestampNanoseconds: event.timestampNanoseconds)
        case .pointerMotion:
            return Event(
                type: event.activeButtons.isEmpty
                    ? .pointerMoved
                    : .pointerDragged,
                modifierFlags: modifiers,
                location: location,
                timestampNanoseconds: event.timestampNanoseconds,
                activeButtons: pointerButtonMask(event.activeButtons),
                pointerTool: .mouse)
        case .pointerButtonDown:
            return Event(
                type: .pointerDown, modifierFlags: modifiers, location: location,
                timestampNanoseconds: event.timestampNanoseconds,
                button: pointerButton(event.button),
                activeButtons: pointerButtonMask(event.activeButtons),
                pointerTool: .mouse,
                clickCount: 1)
        case .pointerButtonUp:
            return Event(
                type: .pointerUp, modifierFlags: modifiers, location: location,
                timestampNanoseconds: event.timestampNanoseconds,
                button: pointerButton(event.button),
                activeButtons: pointerButtonMask(event.activeButtons),
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
                scrollPhase: scrollPhase(event.scrollPhase))
        case .keyDown, .keyUp:
            return Event(
                type: event.kind == .keyDown ? .keyDown : .keyUp,
                modifierFlags: modifiers,
                location: lastLocation,
                timestampNanoseconds: event.timestampNanoseconds,
                keyCode: KeyCode(rawValue: event.key.rawValue),
                characters: event.text,
                isARepeat: event.isRepeat)
        case .pointerLeave, .keyboardEnter, .keyboardLeave,
            .touchDown, .touchMotion, .touchUp, .touchCancel,
            .tabletToolEnter, .tabletToolLeave, .tabletToolMotion,
            .tabletToolButtonDown, .tabletToolButtonUp,
            .focusGained, .focusLost, .textPreedit, .textCommit:
            return nil
        }
    }

    static func modifierFlags(
        _ state: InputModifierFlags
    ) -> EventModifierFlags {
        EventModifierFlags(rawValue: state.rawValue)
    }

    /// Preserve the shared button identity in the UI event vocabulary.
    static func pointerButton(_ code: PointerButtonCode) -> PointerButton {
        PointerButton(rawValue: code.rawValue)
    }

    static func pointerButtonMask(
        _ buttons: PointerButtonSet
    ) -> PointerButtonMask {
        PointerButtonMask(rawValue: buttons.rawValue)
    }

    /// Preserve the shared scroll vocabulary in the UI event vocabulary.
    static func scrollSource(_ source: InputScrollSource) -> ScrollSource {
        switch source {
        case .unknown: .unknown
        case .wheel: .wheel
        case .finger: .finger
        case .continuous: .continuous
        case .wheelTilt: .wheelTilt
        }
    }

    static func scrollPhase(_ phase: InputScrollPhase) -> ScrollPhase {
        switch phase {
        case .none: .none
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        }
    }
}
