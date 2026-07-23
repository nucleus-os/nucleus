// InputDispatch — the compositor's central input-routing orchestration,
// incorporating the EventShortcutTap session tap. It is the spine that turns a
// normalized WireEventRecord into focus
// changes, Wayland-seat delivery, and compositor policy, calling the already-Swift
// owners directly: EventServer + SeatFocus (NucleusCompositorServer), the router WlSeat (via
// SeatDelivery), the window driver, the hit-test, the keybind seam, and the xkb
// keyboard state.
//
// Single-threaded on the compositor main actor; processes one event end-to-end
// before the next. It keeps a cached copy
// of the accepted stream state (cursor/flags/buttons) so pre-dispatch reads (the
// pointer-constraint clamp) see the last-accepted cursor.
//
// Chrome interaction (titlebar drag/resize/control buttons/traffic lights/window
// menu) and overlay-input arbitration call Swift owners directly or through
// Swift-owned C entries. The only remaining nucleus_input_* exports are owned by
// InputHost for seat/libinput bring-up while the reactor
// still drives those lifecycle edges.

internal import NucleusCompositorServer
import NucleusCompositorServerTypes
internal import NucleusCompositorWindowManager
import Glibc

// Cursor + shell/overlay reach-up runs through the inverted `shellPolicy` seam
// (CompositorShellPolicy, defined in `.server`; the shell conforms + installs it).
// The area DAG forbids the input dispatch from importing `.shell`, so these are not
// direct calls — they go through the runtime server's `shellPolicy`. A nil seam
// (before the shell installs it) yields the inert default (no overlay, 0, false).

/// Left/right evdev pointer button codes the chrome path keys on.
package let btnLeft: UInt32 = 0x110
package let btnRight: UInt32 = 0x111
package let doubleClickIntervalMsec: UInt32 = 400

enum CursorIntent: Equatable {
    case named(String)
    case client
}

func resolveCursorIntent(
    resizeName: String?, clientOwnsCursor: Bool, shellControl: Bool
) -> CursorIntent {
    if let resizeName { return .named(resizeName) }
    if clientOwnsCursor { return .client }
    if shellControl { return .named("pointer") }
    return .named("default")
}

@MainActor
final class InputDispatch {
    /// The result the compositor loop acts on after a dispatched event.
    enum Result {
        case delivered
        case consumed
        case exitRequested
        case switchVT(Int32)
    }

    /// Where an event entered the pipeline; only hid/session run the shortcut tap.
    enum TapLocation {
        case hid
        case session
        case annotatedSession
    }

    let xkb: XkbKeyboard
    unowned let host: RouterHost
    package let seatDelivery: SeatDelivery
    package let clientPolicy: InputClientPolicy

    // Cached accepted stream state (mirror of EventServer's, for pre-dispatch reads
    // and the libinput→record normalization snapshot).
    package var cursorX: Double = 0
    package var cursorY: Double = 0
    package var streamFlags: UInt64 = 0
    package var leftButtonDown = false
    package var rightButtonDown = false
    package var otherButtonCount: UInt8 = 0

    // Cursor-focus tracking (the xwayland/default cursor-swap state machine).
    package var pointerFocusWasXwayland = false
    package var cursorFromXwayland = false
    package var cursorOverShellControl = false
    package var appliedCursorIntent: CursorIntent?
    package var inputRouteDiagnosticsRemaining = 24

    package struct TouchGrab {
        var surfaceID: UInt64
        var localOffsetX: Double
        var localOffsetY: Double
    }
    package var touchGrabs: [Int32: TouchGrab] = [:]

    // Chrome interaction state.
    package var armedChromeButton: (windowID: UInt64, region: ChromeRegion)?
    package var lastTitlebarPress: (windowID: UInt64, timeMsec: UInt32)?
    package var chromeButtonVisual: (windowID: UInt64, rootSurface: UInt64, hovered: UInt32, pressed: UInt32)?

    init(xkb: XkbKeyboard, host: RouterHost) {
        self.xkb = xkb
        self.host = host
        let seatDelivery = SeatDelivery(host: host)
        self.seatDelivery = seatDelivery
        self.clientPolicy = InputClientPolicy(
            host: host, seatDelivery: seatDelivery)
    }

    // MARK: - entry

    /// Dispatch one event. `location` selects whether the shortcut tap runs.
    func dispatch(_ record: WireEventRecord, location: TapLocation = .hid) -> Result {
        var submitted = record
        InputLatencyProbe.beginHidEvent()
        host.runtime?.idle.noteUserInput(
            atMs: Self.monotonicNowNs() / 1_000_000)

        if isKey(submitted.kind) { updateKeyboardStateForEvent(&submitted) }
        applyPointerConstraints(&submitted)

        if location == .hid || location == .session {
            switch runShortcutTap(&submitted) {
            case .pass: break
            case .suppress: return .consumed
            case .replace(let replacement): submitted = replacement
            case .dispatch(let result): return result
            }
        }

        let previousCursorX = cursorX
        let previousCursorY = cursorY
        let decision = host.server.events.dispatch(submitted, bounds: pointerBounds())
        cacheState(decision.state)
        if decision.change.cursorMoved {
            requestCursorFrame(
                previousX: previousCursorX,
                previousY: previousCursorY)
        }

        switch decision.action {
        case .route: return route(decision.event)
        case .delivered: return .delivered
        case .consumed: return .consumed
        case .exitRequested: return .exitRequested
        case .switchVt: return .switchVT(decision.dispatchValue)
        @unknown default: return .consumed
        }
    }

    package func route(_ event: WireEventRecord) -> Result {
        switch event.kind {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            processCursorMotion(event)
            return .delivered
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            handleMouseButton(event)
            return .delivered
        case .scrollWheel:
            handleScroll(event)
            return .delivered
        case .keyDown, .keyUp:
            return handleKey(event)
        case .touchDown, .touchUp, .touchMotion, .touchCancel, .touchFrame:
            handleTouch(event)
            return .delivered
        default:
            return .delivered
        }
    }

}
