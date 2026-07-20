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

import NucleusCompositorServer
import NucleusCompositorServerTypes
import NucleusCompositorWindowManager
import Glibc

// Cursor + shell/overlay reach-up runs through the inverted `shellPolicy` seam
// (CompositorShellPolicy, defined in `.server`; the shell conforms + installs it).
// The area DAG forbids the input dispatch from importing `.shell`, so these are not
// direct calls — they go through `NucleusCompositorServer.shared.shellPolicy`. A nil seam
// (before the shell installs it) yields the inert default (no overlay, 0, false).

/// Left/right evdev pointer button codes the chrome path keys on.
private let btnLeft: UInt32 = 0x110
private let btnRight: UInt32 = 0x111
private let doubleClickIntervalMsec: UInt32 = 400

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
    private let clientPolicy = InputClientPolicy()

    // Cached accepted stream state (mirror of EventServer's, for pre-dispatch reads
    // and the libinput→record normalization snapshot).
    private var cursorX: Double = 0
    private var cursorY: Double = 0
    private var streamFlags: UInt64 = 0
    private var leftButtonDown = false
    private var rightButtonDown = false
    private var otherButtonCount: UInt8 = 0

    // Cursor-focus tracking (the xwayland/default cursor-swap state machine).
    private var pointerFocusWasXwayland = false
    private var cursorFromXwayland = false
    private var cursorOverShellControl = false
    private var appliedCursorIntent: CursorIntent?
    private var inputRouteDiagnosticsRemaining = 24

    private struct TouchGrab {
        var surfaceID: UInt64
        var localOffsetX: Double
        var localOffsetY: Double
    }
    private var touchGrabs: [Int32: TouchGrab] = [:]

    // Chrome interaction state.
    private var armedChromeButton: (windowID: UInt64, region: ChromeRegion)?
    private var lastTitlebarPress: (windowID: UInt64, timeMsec: UInt32)?
    private var chromeButtonVisual: (windowID: UInt64, rootSurface: UInt64, hovered: UInt32, pressed: UInt32)?

    init(xkb: XkbKeyboard) { self.xkb = xkb }

    static func monotonicNowNs() -> UInt64 {
        var timestamp = timespec()
        clock_gettime(CLOCK_MONOTONIC, &timestamp)
        return UInt64(timestamp.tv_sec) &* 1_000_000_000
            &+ UInt64(timestamp.tv_nsec)
    }

    // MARK: - backend-facing surface (the input host drives these)

    /// The stream snapshot the libinput→record normalization reads (current cursor,
    /// modifier flags, and button state for the drag-kind decision).
    func currentSnapshot() -> InputStreamSnapshot {
        InputStreamSnapshot(
            cursorX: cursorX, cursorY: cursorY, flags: streamFlags,
            leftDown: leftButtonDown, rightDown: rightButtonDown, otherCount: otherButtonCount)
    }

    /// Emit a wl_pointer.frame to the focused surface after a pointer event batch.
    func deliverPointerFrame() {
        let target = pointerFocusID()
        if target != 0 { SeatDelivery.pointerFrame(surfaceID: target) }
    }

    /// Begin a compositor-driven interactive move/resize grab (the window-menu
    /// Move/Resize verbs, reached from the overlay publication callback).
    func beginInteractiveMove(windowID: UInt64) { beginInteractiveMoveFromChrome(windowID: windowID) }
    func beginInteractiveResize(windowID: UInt64, edges: UInt32) {
        beginInteractiveResizeFromChrome(windowID: windowID, edges: edges)
    }
    func showWindowMenu(windowID: UInt64) {
        showWindowMenuForWindow(windowID)
    }

    /// Clear pointer focus (the orchestration calls this on unmap / lock).
    func clearPointerFocus() { clearPointerFocusSurface() }

    /// Clear keyboard focus (minimize / session lock / unmap). Emits
    /// wl_keyboard.leave to the prior surface.
    func clearKeyboardFocus() {
        let old = keyboardFocusID()
        if old == 0 { return }
        seatFocus.clearKeyboardFocus()
        SeatDelivery.keyboardLeave(surfaceID: old)
    }

    func clearKeyboardFocus(ifWindow windowID: UInt64) {
        let surfaceID = keyboardFocusID()
        if surfaceID == 0 { return }
        guard windowDriver?.windowId(forSurfaceId: UInt32(truncatingIfNeeded: surfaceID)) == windowID else { return }
        clearKeyboardFocus()
    }

    /// Reset keyboard + pointer state on a session (VT) reactivation: stuck modifiers
    /// and implicit grabs from the other VT are cleared.
    func resetKeyboardState() {
        xkb.updateMask(depressed: 0, latched: 0, locked: 0, group: 0)
        xkb.resetPressedKeys()
        clientPolicy.reset()
        NucleusCompositorServer.shared.events.resetInputState()
        streamFlags = 0
        leftButtonDown = false
        rightButtonDown = false
        otherButtonCount = 0
        let target = keyboardFocusID()
        if target != 0 {
            SeatDelivery.keyboardModifiers(surfaceID: target, depressed: 0, latched: 0, locked: 0, group: 0)
        }
        seatFocus.resetPointerButtons()
        WindowManager.shared.endInteractiveGrab()
    }

    /// Clear every focus and grab that was authorized by the departing session.
    /// No serial or implicit grab may survive a VT boundary.
    func resetSessionState() {
        clearPointerFocus()
        clearKeyboardFocus()
        touchGrabs.removeAll(keepingCapacity: true)
        armedChromeButton = nil
        lastTitlebarPress = nil
        chromeButtonVisual = nil
        resetKeyboardState()
    }

    // MARK: - reachable Swift owners

    private var seatFocus: SeatFocus { NucleusCompositorServer.shared.seatFocus }
    private var windowDriver: RouterWindowDriver? { RouterHost.shared.runtime?.windowDriver }

    private func pointerFocusID() -> UInt64 { seatFocus.pointerSurfaceID }
    private func keyboardFocusID() -> UInt64 { seatFocus.keyboardSurfaceID }

    // MARK: - session-lock gate

    private func lockActive() -> Bool {
        SessionLockGate.isActive()
    }

    /// While locked, focus/events may only land on a lock surface (source 4); an
    /// unowned surface (0) fails closed.
    private func lockBlocks(_ surfaceID: UInt64) -> Bool {
        if !lockActive() { return false }
        if surfaceID == 0 { return true }
        let source = windowDriver?.windowSource(forSurfaceId: UInt32(truncatingIfNeeded: surfaceID)) ?? 0
        return source != 4
    }

    // MARK: - focus management

    private func setPointerFocusSurface(_ surfaceID: UInt64, sx: Double, sy: Double) {
        if lockBlocks(surfaceID) { return }
        let old = pointerFocusID()
        if old == surfaceID { return }
        seatFocus.setPointerFocus(surfaceID: surfaceID)
        if inputRouteDiagnosticsRemaining > 0 {
            inputRouteDiagnosticsRemaining -= 1
            let source = windowDriver?.windowSource(forSurfaceId: UInt32(truncatingIfNeeded: surfaceID)) ?? 0
            let line = "input-route: focus old=\(old) new=\(surfaceID) source=\(source) local=\(sx),\(sy)\n"
            line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
        }
        if old != 0 { SeatDelivery.pointerLeave(surfaceID: old) }
        if surfaceID != 0 { SeatDelivery.pointerEnter(surfaceID: surfaceID, x: sx, y: sy) }
    }

    private func clearPointerFocusSurface() {
        let old = pointerFocusID()
        if old == 0 { return }
        seatFocus.clearPointerFocus()
        SeatDelivery.pointerLeave(surfaceID: old)
    }

    private func setKeyboardFocusSurface(_ surfaceID: UInt64) {
        if lockBlocks(surfaceID) { return }
        let old = keyboardFocusID()
        if old == surfaceID { return }
        seatFocus.setKeyboardFocus(surfaceID: surfaceID)
        if surfaceID != 0, let wd = windowDriver {
            let windowID = wd.windowId(forSurfaceId: UInt32(truncatingIfNeeded: surfaceID))
            if windowID != 0 {
                NucleusCompositorServer.shared.windows.focus(id: windowID)
            }
        }
        if old != 0 { SeatDelivery.keyboardLeave(surfaceID: old) }
        if surfaceID != 0 { SeatDelivery.keyboardEnter(surfaceID: surfaceID) }
        // Re-drive xdg activation for the focus change (model focus + configure; the
        // seat enter/leave above already delivered the wl_keyboard transition).
        windowDriver?.publishKeyboardFocus(
            oldSurfaceId: UInt32(truncatingIfNeeded: old),
            newSurfaceId: UInt32(truncatingIfNeeded: surfaceID))
    }

    // MARK: - entry

    /// Dispatch one event. `location` selects whether the shortcut tap runs.
    func dispatch(_ record: WireEventRecord, location: TapLocation = .hid) -> Result {
        var submitted = record
        InputLatencyProbe.beginHidEvent()
        WaylandRuntime.noteUserInput(nowNs: Self.monotonicNowNs())

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
        let decision = NucleusCompositorServer.shared.events.dispatch(submitted, bounds: pointerBounds())
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

    private func route(_ event: WireEventRecord) -> Result {
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

    private func handleTouch(_ event: WireEventRecord) {
        let id = Int32(bitPattern: UInt32(truncatingIfNeeded: event.data0))
        switch event.kind {
        case .touchDown:
            let hit = routerHitTest(sx: event.x, sy: event.y)
            guard hit.surfaceId != 0, !lockBlocks(hit.surfaceId) else { return }
            touchGrabs[id] = TouchGrab(
                surfaceID: hit.surfaceId,
                localOffsetX: hit.localX - event.x,
                localOffsetY: hit.localY - event.y)
            SeatDelivery.touchDown(
                surfaceID: hit.surfaceId, timeMsec: msec(event), id: id,
                x: hit.localX, y: hit.localY)
        case .touchMotion:
            if RouterHost.shared.runtime?.dataDevice.dragActive == true {
                let hit = routerHitTest(sx: event.x, sy: event.y)
                _ = RouterHost.shared.runtime?.dataDevice.dragMotion(
                    surfaceID: hit.surfaceId,
                    x: hit.localX,
                    y: hit.localY,
                    timeMsec: msec(event))
                return
            }
            guard let grab = touchGrabs[id], !lockBlocks(grab.surfaceID) else { return }
            SeatDelivery.touchMotion(
                surfaceID: grab.surfaceID, timeMsec: msec(event), id: id,
                x: event.x + grab.localOffsetX, y: event.y + grab.localOffsetY)
        case .touchUp:
            guard let grab = touchGrabs.removeValue(forKey: id), !lockBlocks(grab.surfaceID) else { return }
            SeatDelivery.touchUp(surfaceID: grab.surfaceID, timeMsec: msec(event), id: id)
            if touchGrabs.isEmpty {
                _ = RouterHost.shared.runtime?.dataDevice.dropActiveDrag()
            }
        case .touchFrame:
            for surfaceID in Set(touchGrabs.values.map(\.surfaceID)) {
                SeatDelivery.touchFrame(surfaceID: surfaceID)
            }
        case .touchCancel:
            for surfaceID in Set(touchGrabs.values.map(\.surfaceID)) {
                SeatDelivery.touchCancel(surfaceID: surfaceID)
            }
            touchGrabs.removeAll(keepingCapacity: true)
            RouterHost.shared.runtime?.dataDevice.cancelActiveDrag(
                notifySource: true)
        default:
            break
        }
    }

    // MARK: - shortcut tap (session keybind policy)

    private enum ShortcutTapResult {
        case pass
        case suppress
        case replace(WireEventRecord)
        case dispatch(Result)
    }

    private func runShortcutTap(_ record: inout WireEventRecord) -> ShortcutTapResult {
        guard isKey(record.kind) else { return .pass }
        let keycode = UInt32(truncatingIfNeeded: record.data0)
        let pressed = record.kind == .keyDown
        let control = record.flags & EventFlagBit.control != 0
        let alternate = record.flags & EventFlagBit.alternate != 0

        // System-level escape hatches run before the remappable Swift policy.
        if pressed && control && alternate {
            if keycode == 14 { return .dispatch(.exitRequested) }  // Ctrl+Alt+Backspace
            if let vt = vtForEvdevKey(keycode) { return .dispatch(.switchVT(vt)) }
        }

        // While locked, keys flow straight to the focused lock surface — no compositor
        // keybind policy. (The system hatches above intentionally remain available.)
        if lockActive() { return .pass }

        // Honour an active keyboard-shortcuts inhibitor on the focused surface.
        let keyboardSurface = keyboardFocusID()
        if keyboardSurface != 0 && SeatDelivery.isInhibited(surfaceID: keyboardSurface) {
            return .pass
        }

        // Session-policy layer (the shell, via the inverted seam).
        guard let shell = NucleusCompositorServer.shared.shellPolicy else { return .pass }
        let outcome = shell.dispatchKeybind(keycode: keycode, modifiers: record.flags, pressed: pressed)
        switch outcome.kind {
        case .consume:
            return .suppress
        case .deferred:
            executeDeferredAction(action: outcome.action, value: outcome.value)
            return .suppress
        case .pass:
            return .pass
        }
    }

    /// Run the window verb a deferred keybind named. Swift-owned window/workspace
    /// actions run directly; shell/overlay actions still cross to their owners.
    private func executeDeferredAction(action: UInt8, value: UInt32) {
        switch action {
        case 1:  // close_focused
            let surface = keyboardFocusID()
            if surface != 0 { windowDriver?.close(surfaceId: UInt32(truncatingIfNeeded: surface)) }
        case 3:  // toggle_hotkey
            NucleusCompositorServer.shared.shellPolicy?.toggleHotkey()
            requestOverlayFrame()
        case 4:  // dismiss_hotkey
            NucleusCompositorServer.shared.shellPolicy?.dismissHotkey()
            requestOverlayFrame()
        // case 5: RESERVED (formerly wallpaper cycle; wallpaper is now a
        // background-layer wlr-layer-shell client, not compositor-owned).
        case 6:  // window_menu (for the focused window)
            let surface = keyboardFocusID()
            if surface != 0, let windowID = windowDriver?.windowId(forSurfaceId: UInt32(truncatingIfNeeded: surface)),
                windowID != 0 {
                showWindowMenuForWindow(windowID)
            }
        case 7:  // tile (value carries the TileCommand raw)
            let surface = keyboardFocusID()
            if surface != 0 {
                _ = windowDriver?.tile(surfaceId: UInt32(truncatingIfNeeded: surface), command: value)
            }
        case 8:  // backdrop_changed (Swift already mutated the model; schedule a frame)
            RenderBridge.requestFrame(outputId: 0)
        case 9:  // activate_workspace (value: 1-based index)
            activateWorkspace(index: value)
        case 10:  // move_window_to_workspace (value: 1-based index)
            moveFocusedWindowToWorkspace(index: value)
        default:
            break
        }
    }

    // MARK: - keyboard

    private func handleKey(_ event: WireEventRecord) -> Result {
        let keycode = UInt32(truncatingIfNeeded: event.data0)
        let pressed = event.kind == .keyDown

        // The overlay holds the keyboard grab whenever it wants keys — an open
        // window menu, or a focused text field in its own scene. Every key is
        // consumed so the client below stays frozen. Suppressed while locked:
        // the lock screen owns the keyboard, and overlay UI must not be drivable
        // behind it.
        if !lockActive(), NucleusCompositorServer.shared.shellPolicy?.overlaySceneWantsKeyboard() ?? false {
            // Composed text, not a keycode-derived guess: XKB accounts for the
            // layout, dead keys, and compose sequences that a keycode cannot.
            // Press only — a release commits nothing.
            let text = pressed ? xkb.keyGetText(xkbKeycode: keycode + XkbKeyboard.evdevKeycodeOffset) : nil
            _ = dispatchOverlayKey(
                keycode: keycode,
                modifiers: UInt32(truncatingIfNeeded: event.flags),
                text: text,
                kind: pressed ? 5 : 6,
                timestampNs: event.timestampNs)
            return .consumed
        }

        let target = keyboardFocusID()
        if target == 0 { return .delivered }
        if lockBlocks(target) { return .delivered }

        let timeMsec = msec(event)
        let modsAfter = xkb.serializedModifiers()

        // Client-translated path (Command->Control): skipped when an inhibitor is active.
        if !SeatDelivery.isInhibited(surfaceID: target) {
            let policy = InputClientPolicy.policy(forSurfaceID: target)
            let commandActive = event.flags & EventFlagBit.command != 0
            if clientPolicy.handleClientKey(
                surfaceID: target, keycode: keycode, pressed: pressed, timeMsec: timeMsec,
                commandActive: commandActive, policy: policy,
                physical: modsAfter, masks: xkb.modifierMasks())
            {
                return .delivered
            }
        }

        SeatDelivery.keyboardKey(
            surfaceID: target, timeMsec: timeMsec, keycode: keycode, keyState: pressed ? 1 : 0)
        InputLatencyProbe.markDelivery(.keyboardKey)
        SeatDelivery.keyboardModifiers(
            surfaceID: target, depressed: modsAfter.depressed, latched: modsAfter.latched,
            locked: modsAfter.locked, group: modsAfter.group)
        return .delivered
    }

    private func updateKeyboardStateForEvent(_ event: inout WireEventRecord) {
        guard isKey(event.kind) else { return }
        let keycode = UInt32(truncatingIfNeeded: event.data0)
        let pressed = event.kind == .keyDown
        let seatKeyCount: UInt32? = event.data2 == UInt64.max ? nil : UInt32(truncatingIfNeeded: event.data2)
        xkb.updateKey(evdevKeycode: keycode, pressed: pressed, seatKeyCount: seatKeyCount)
        event.flags = xkb.flagsRaw()
        streamFlags = event.flags
    }

    // MARK: - pointer

    private func processCursorMotion(_ event: WireEventRecord) {
        // An active interactive move/resize grab owns motion until release.
        if WindowManager.shared.interactiveGrabActive() {
            updateInteractiveGrab()
            return
        }
        let sx = cursorX
        let sy = cursorY
        let hit = routerHitTest(sx: sx, sy: sy)
        if RouterHost.shared.runtime?.dataDevice.dragMotion(
            surfaceID: hit.surfaceId,
            x: hit.localX,
            y: hit.localY,
            timeMsec: msec(event)) == true
        {
            return
        }
        let chromeRegion = ChromeRegion(rawValue: hit.chromeRegion) ?? .content
        let chromeIsChrome = chromeRegion != .content && hit.windowId != 0

        var candidate = PointerCandidate(surfaceID: nil, surfaceX: sx, surfaceY: sy)
        if hit.surfaceId != 0 {
            candidate = PointerCandidate(
                surfaceID: hit.surfaceId, surfaceX: hit.localX, surfaceY: hit.localY,
                windowID: hit.windowId != 0 ? hit.windowId : nil,
                origin: InputTargeting.origin(fromSource: hit.windowSource))
        }

        // Implicit pointer grab: while a button is held, motion sticks to the focused
        // surface even when it leaves that surface's hit area.
        let pointerFocus = pointerFocusID()
        if candidate.surfaceID == nil && seatFocus.buttonCount > 0 && pointerFocus != 0 {
            candidate = PointerCandidate(
                surfaceID: pointerFocus, surfaceX: sx, surfaceY: sy,
                origin: pointerFocusWasXwayland ? .xwayland : .none)
        }

        let decision = InputTargeting.resolvePointerTarget(
            candidate,
            state: PointerTargetingState(
                pointerFocusID: pointerFocus != 0 ? pointerFocus : nil,
                pointerWasXwayland: pointerFocusWasXwayland,
                cursorFromXwayland: cursorFromXwayland))

        // Cursor-image swap on an xwayland<->client transition (device crossing).
        if decision.shouldApplyXwaylandCursor {
            cursorFromXwayland = nucleus_compositor_xwm_reapply_cursor()
            appliedCursorIntent = cursorFromXwayland ? .client : nil
        } else if decision.shouldRestoreDefaultCursor {
            // Pointer focus left the client: drop its set_cursor binding so its later
            // surface commits no longer control the cursor, then restore the default.
            PointerCursorSurface.clear()
            NucleusCompositorServer.shared.shellPolicy?.cursorApplyDefault()
            requestCursorFrame()
            cursorFromXwayland = false
            appliedCursorIntent = .named("default")
        }
        pointerFocusWasXwayland = decision.rememberPointerXwayland

        // Compositor-policy cursor/overlay hints are suppressed while locked — no
        // shell overlay and no window chrome may react to the pointer behind the lock.
        if !lockActive() {
            // Shell overlay arbitration: while a shell control is up, route motion into
            // the overlay and flip the cursor to the pointer hand over a clickable control.
            var shellControl = false
            if NucleusCompositorServer.shared.shellPolicy?.overlayActive() ?? false {
                let bits = dispatchOverlayPointer(kind: 1, button: 0, timestampNs: event.timestampNs)
                shellControl = bits & 2 != 0
            }
            cursorOverShellControl = shellControl

            // Resolve the cursor afresh from the same presented-scene hit on every
            // motion. No sticky resize flag survives a changed target.
            let resizeName = chromeIsChrome && chromeRegion == .resize
                ? resizeCursorName(edges: hit.chromeEdges) : nil
            applyCursorIntent(resolveCursorIntent(
                resizeName: resizeName,
                clientOwnsCursor: PointerCursorSurface.surfaceId != 0 || cursorFromXwayland,
                shellControl: shellControl))
            updateChromeButtonVisual(windowID: chromeIsChrome ? hit.windowId : 0, region: chromeRegion)
        }

        if let targetID = decision.target.surfaceID {
            if decision.pointerFocusChanged {
                setPointerFocusSurface(targetID, sx: decision.target.surfaceX, sy: decision.target.surfaceY)
            }
            deliverPointerMotion(event, surfaceID: targetID,
                                 sx: decision.target.surfaceX, sy: decision.target.surfaceY)
        } else {
            clearPointerFocusSurface()
        }
    }

    private func handleMouseButton(_ event: WireEventRecord) {
        let button = UInt32(truncatingIfNeeded: event.data0)
        let down = isButtonDown(event.kind)
        let timeMsec = msec(event)

        // While the session is locked, deny every compositor-policy branch below —
        // shell-overlay routing, interactive grabs, window chrome (raise / move /
        // resize / maximize / close / window-menu), and click-to-focus — and deliver
        // only to the focused lock surface. `deliverPointerButton` is lock-gated, so a
        // press that isn't over a lock surface reaches nothing.
        if lockActive() {
            deliverPointerButton(event, button: button, down: down)
            return
        }

        if RouterHost.shared.runtime?.dataDevice.dragActive == true {
            deliverPointerButton(event, button: button, down: down)
            if !down, seatFocus.buttonCount == 0 {
                _ = RouterHost.shared.runtime?.dataDevice.dropActiveDrag()
            }
            return
        }

        // Shell-overlay arbitration: a button up, or any button while the overlay is
        // active, routes into the overlay first; a consumed event stops here.
        if !down || (NucleusCompositorServer.shared.shellPolicy?.overlayActive() ?? false) {
            let bits = dispatchOverlayPointer(kind: down ? 2 : 3, button: button, timestampNs: event.timestampNs)
            if bits & 1 != 0 { return }
        }

        // An active interactive grab consumes the button; the last release finishes it.
        if WindowManager.shared.interactiveGrabActive() {
            deliverPointerButton(event, button: button, down: down)
            if !down && seatFocus.buttonCount == 0 { finishInteractiveGrab(timeMsec: timeMsec) }
            return
        }

        // A release with an armed control button fires/cancels its verb, then delivers
        // only to balance the button bookkeeping (focus is null over chrome).
        if !down && armedChromeButton != nil {
            handleChromeButtonRelease()
            deliverPointerButton(event, button: button, down: down)
            return
        }

        if down {
            if handleChromePress(button: button, timeMsec: timeMsec) {
                deliverPointerButton(event, button: button, down: down)
                return
            }
            focusAndRaiseWindowUnderPointer()
        }
        deliverPointerButton(event, button: button, down: down)
    }

    private func handleScroll(_ event: WireEventRecord) {
        let target = pointerFocusID()
        if target == 0 || lockBlocks(target) { return }
        let delta = Double(bitPattern: event.data0)
        let value120 = Int32(bitPattern: UInt32(truncatingIfNeeded: event.data1))
        let orientation = UInt32(truncatingIfNeeded: event.data2)
        let source = UInt32(truncatingIfNeeded: event.data3)
        SeatDelivery.pointerAxis(
            surfaceID: target, timeMsec: msec(event), axis: orientation,
            delta: delta, value120: value120, source: source)
    }

    private func deliverPointerMotion(_ event: WireEventRecord, surfaceID: UInt64, sx: Double, sy: Double) {
        if lockBlocks(surfaceID) { return }
        SeatDelivery.pointerMotionRaw(
            surfaceID: surfaceID, timeMsec: msec(event), surfaceX: sx, surfaceY: sy,
            dx: Double(bitPattern: event.data0), dy: Double(bitPattern: event.data1),
            dxUnaccel: Double(bitPattern: event.data2), dyUnaccel: Double(bitPattern: event.data3))
        InputLatencyProbe.markDelivery(.pointerMotion)
    }

    private func deliverPointerButton(_ event: WireEventRecord, button: UInt32, down: Bool) {
        var serial: UInt32 = 0
        let target = pointerFocusID()
        if inputRouteDiagnosticsRemaining > 0 {
            inputRouteDiagnosticsRemaining -= 1
            let source = target == 0 ? 0 : (windowDriver?.windowSource(
                forSurfaceId: UInt32(truncatingIfNeeded: target)) ?? 0)
            let line = "input-route: button=\(button) down=\(down) target=\(target) source=\(source) cursor=\(cursorX),\(cursorY)\n"
            line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
        }
        if target != 0 && !lockBlocks(target) {
            serial = SeatDelivery.pointerButton(
                surfaceID: target, timeMsec: msec(event), button: button, state: down ? 1 : 0)
            InputLatencyProbe.markDelivery(.pointerButton)
        }
        seatFocus.recordPointerButton(state: down ? 1 : 0, serial: serial, focusedSurfaceID: target)
    }

    /// Click-to-focus + raise-on-click: a press inside a window focuses it (unless it
    /// already holds keyboard focus) before the press is delivered.
    private func focusAndRaiseWindowUnderPointer() {
        let surfaceID = pointerFocusID()
        if surfaceID == 0 { return }
        guard let wd = windowDriver else { return }
        if wd.focusSurfaceForPress(surfaceId: UInt32(truncatingIfNeeded: surfaceID)) {
            if keyboardFocusID() == surfaceID { return }
            setKeyboardFocusSurface(surfaceID)
        }
    }

    /// Locked/confined pointer constraint clamping, applied before the event reaches
    /// EventServer.apply. Locked freezes the cursor; confined clamps to the focused
    /// window's animated rect. Motion deltas in the payload are preserved.
    private func applyPointerConstraints(_ event: inout WireEventRecord) {
        guard isMotion(event.kind) else { return }
        let surfaceID = pointerFocusID()
        if surfaceID == 0 { return }
        switch SeatDelivery.pointerConstraintKind(surfaceID: surfaceID) {
        case 1:  // locked
            event.x = cursorX
            event.y = cursorY
        case 2:  // confined
            guard let rect = RouterHost.shared.feeder?.presentedWindow(
                surfaceID: UInt32(truncatingIfNeeded: surfaceID))?.frame else { return }
            event.x = min(max(event.x, rect.x), rect.x + rect.w - 1)
            event.y = min(max(event.y, rect.y), rect.y + rect.h - 1)
        default:
            break
        }
    }

    // MARK: - chrome interaction

    /// The front-most window whose server-drawn chrome the cursor is over, and where.
    /// Returns nil over client content or empty space (those follow normal routing).
    private func chromeHitUnderCursor() -> (windowID: UInt64, surfaceID: UInt64, region: ChromeRegion, edges: UInt32)? {
        let hit = routerHitTest(sx: cursorX, sy: cursorY)
        let region = ChromeRegion(rawValue: hit.chromeRegion) ?? .content
        if region == .content || hit.windowId == 0 { return nil }
        let surfaceID = windowDriver?.rootSurface(forWindowId: hit.windowId) ?? 0
        return (hit.windowId, surfaceID, region, hit.chromeEdges)
    }

    /// Route a press on server-drawn chrome: focus + raise, then begin a move
    /// (titlebar) / resize (edge) grab, arm a control button, double-click-maximize,
    /// or open the window menu (right-click titlebar). Returns true when the press
    /// was chrome and must not reach the client.
    private func handleChromePress(button: UInt32, timeMsec: UInt32) -> Bool {
        guard let chrome = chromeHitUnderCursor() else { return false }
        armedChromeButton = nil
        raiseWindow(chrome.windowID)
        if chrome.surfaceID != 0,
            windowDriver?.focusSurfaceForPress(surfaceId: UInt32(truncatingIfNeeded: chrome.surfaceID)) == true {
            setKeyboardFocusSurface(chrome.surfaceID)
        }
        switch chrome.region {
        case .titlebar:
            if button == btnRight {
                showWindowMenuForWindow(chrome.windowID)
                return true
            }
            if button != btnLeft { return true }
            if isTitlebarDoubleClick(windowID: chrome.windowID, timeMsec: timeMsec) {
                lastTitlebarPress = nil
                if chrome.surfaceID != 0 {
                    windowDriver?.toggleMaximize(surfaceId: UInt32(truncatingIfNeeded: chrome.surfaceID))
                }
                return true
            }
            lastTitlebarPress = (chrome.windowID, timeMsec)
            beginInteractiveMoveFromChrome(windowID: chrome.windowID)
        case .resize:
            if button == btnLeft {
                beginInteractiveResizeFromChrome(windowID: chrome.windowID, edges: chrome.edges)
            }
        case .closeButton, .minimizeButton, .maximizeButton:
            if button == btnLeft {
                armedChromeButton = (chrome.windowID, chrome.region)
                updateChromeButtonVisual(windowID: chrome.windowID, region: chrome.region)
            }
        default:
            return false
        }
        return true
    }

    /// On release of an armed control button, fire its verb iff the cursor is still
    /// over the same button; a drifted release cancels.
    private func handleChromeButtonRelease() {
        guard let armed = armedChromeButton else { return }
        armedChromeButton = nil
        let chrome = chromeHitUnderCursor()
        if let chrome, chrome.windowID == armed.windowID, chrome.region == armed.region {
            switch armed.region {
            case .closeButton:
                if chrome.surfaceID != 0 { windowDriver?.close(surfaceId: UInt32(truncatingIfNeeded: chrome.surfaceID)) }
            case .maximizeButton:
                if chrome.surfaceID != 0 { windowDriver?.toggleMaximize(surfaceId: UInt32(truncatingIfNeeded: chrome.surfaceID)) }
            case .minimizeButton:
                _ = windowDriver?.minimize(windowId: armed.windowID)
            default:
                break
            }
        }
        if let chrome {
            updateChromeButtonVisual(windowID: chrome.windowID, region: chrome.region)
        } else {
            updateChromeButtonVisual(windowID: 0, region: .content)
        }
    }

    /// Reconcile the traffic-light highlight with the cursor: light the hovered
    /// button, darken it while armed, and clear the prior window when the highlight
    /// moves off. Pushes only on change, keyed by the root surface id.
    private func updateChromeButtonVisual(windowID: UInt64, region: ChromeRegion) {
        var targetID: UInt64 = 0
        var targetRoot: UInt64 = 0
        var hovered: UInt32 = 0
        var pressed: UInt32 = 0
        if windowID != 0 {
            let code = chromeButtonCode(region)
            if code != 0, let root = windowDriver?.rootSurface(forWindowId: windowID), root != 0 {
                targetID = windowID
                targetRoot = root
                hovered = code
                if let armed = armedChromeButton, armed.windowID == windowID,
                    chromeButtonCode(armed.region) == code {
                    pressed = code
                }
            }
        }
        if let prev = chromeButtonVisual {
            if prev.windowID == targetID && prev.hovered == hovered && prev.pressed == pressed { return }
            if prev.windowID != targetID && (prev.hovered != 0 || prev.pressed != 0) {
                RouterHost.shared.feeder?.setChromeButtonState(rootSurfaceID: prev.rootSurface, hovered: 0, pressed: 0)
            }
        }
        if targetID == 0 {
            chromeButtonVisual = nil
            return
        }
        RouterHost.shared.feeder?.setChromeButtonState(rootSurfaceID: targetRoot, hovered: hovered, pressed: pressed)
        chromeButtonVisual = (targetID, targetRoot, hovered, pressed)
    }

    /// Open the per-window menu at the cursor (right-click titlebar / menu keybind).
    private func showWindowMenuForWindow(_ windowID: UInt64) {
        guard windowID != 0 else { return }
        NucleusCompositorServer.shared.shellPolicy?.overlaySceneShowWindowMenu(
            windowID: windowID,
            x: cursorX,
            y: cursorY,
            capabilities: NucleusCompositorServer.shared.windowCapabilities(id: windowID))
    }

    private func overlayScaleAtCursor() -> Double {
        for display in NucleusCompositorServer.shared.layout.displays {
            let r = display.logicalRect
            if cursorX >= r.x && cursorX < r.maxX && cursorY >= r.y && cursorY < r.maxY {
                return display.fractionalScale
            }
        }
        return 1
    }

    private func dispatchOverlayPointer(kind: UInt32, button: UInt32, timestampNs: UInt64) -> UInt32 {
        let scale = overlayScaleAtCursor()
        let result = NucleusCompositorServer.shared.shellPolicy?.overlayPointer(
            x: Float(cursorX * scale),
            y: Float(cursorY * scale),
            kind: kind,
            button: button,
            timestampNs: timestampNs) ?? 0
        let bits = UInt32(truncatingIfNeeded: result)
        applyOverlayResult(bits: bits)
        return bits
    }

    private func dispatchOverlayKey(
        keycode: UInt32, modifiers: UInt32, text: String?, kind: UInt32, timestampNs: UInt64
    ) -> UInt32 {
        let result = NucleusCompositorServer.shared.shellPolicy?.overlayKey(
            keycode: keycode, modifiers: modifiers, text: text,
            kind: kind, timestampNs: timestampNs) ?? 0
        let bits = UInt32(truncatingIfNeeded: result)
        applyOverlayResult(bits: bits)
        return bits
    }

    private func applyOverlayResult(bits: UInt32) {
        if bits & 4 != 0 {
            requestOverlayFrame()
        }
    }

    private func requestOverlayFrame() {
        let server = NucleusCompositorServer.shared
        RenderBridge.requestFrame(
            outputId: server.spaces.overlayDisplayID(
                layout: server.layout),
            reason: .shellOverlay)
    }

    private func workspaceTargetOutput() -> UInt64 {
        let surface = keyboardFocusID()
        if surface != 0 {
            let output = windowDriver?.windowOutput(forSurfaceId: UInt32(truncatingIfNeeded: surface)) ?? 0
            if output != 0 { return output }
        }
        let layout = NucleusCompositorServer.shared.layout
        return layout.primaryDisplayID() ?? layout.displays.first?.id ?? 0
    }

    private func raiseWindow(_ windowID: UInt64) {
        guard windowID != 0 else { return }
        if NucleusCompositorServer.shared.windows.raise(id: windowID) {
            RenderBridge.requestFrame(
                forWindowID: windowID)
        }
    }

    private func activateWorkspace(index: UInt32) {
        guard index != 0 else { return }
        let outputID = workspaceTargetOutput()
        guard outputID != 0 else { return }
        let server = NucleusCompositorServer.shared
        let spaceID = server.spaces.ensureWorkspace(onOutput: outputID, index: Int(index))
        guard spaceID != 0 else { return }
        if server.spaces.setActiveSpace(spaceID, forDisplay: outputID) {
            RenderBridge.requestFrame(outputId: outputID)
        }
    }

    private func moveFocusedWindowToWorkspace(index: UInt32) {
        guard index != 0 else { return }
        let surface = keyboardFocusID()
        guard surface != 0 else { return }
        let windowID = windowDriver?.windowId(forSurfaceId: UInt32(truncatingIfNeeded: surface)) ?? 0
        guard windowID != 0 else { return }
        var outputID = windowDriver?.windowOutput(forSurfaceId: UInt32(truncatingIfNeeded: surface)) ?? 0
        if outputID == 0 { outputID = workspaceTargetOutput() }
        guard outputID != 0 else { return }
        let server = NucleusCompositorServer.shared
        let spaceID = server.spaces.ensureWorkspace(onOutput: outputID, index: Int(index))
        guard spaceID != 0 else { return }
        if server.spaces.assign(window: windowID, toSpace: spaceID) {
            RenderBridge.requestFrame(outputId: outputID)
        }
    }

    private func isTitlebarDoubleClick(windowID: UInt64, timeMsec: UInt32) -> Bool {
        guard let prev = lastTitlebarPress, prev.windowID == windowID else { return false }
        // The wrapping evdev millisecond clock; the interval is tiny next to the wrap.
        return (timeMsec &- prev.timeMsec) <= doubleClickIntervalMsec
    }

    /// 1-based control-button code for the scene author (1 close, 2 minimize, 3 maximize).
    private func chromeButtonCode(_ region: ChromeRegion) -> UInt32 {
        switch region {
        case .closeButton: return 1
        case .minimizeButton: return 2
        case .maximizeButton: return 3
        default: return 0
        }
    }

    private func resizeCursorName(edges: UInt32) -> String {
        let left = edges & 1 != 0, right = edges & 2 != 0, top = edges & 4 != 0, bottom = edges & 8 != 0
        if (top && left) || (bottom && right) { return "nwse-resize" }
        if (top && right) || (bottom && left) { return "nesw-resize" }
        if left || right { return "ew-resize" }
        if top || bottom { return "ns-resize" }
        return "default"
    }

    private func applyNamedCursor(_ name: String) {
        NucleusCompositorServer.shared.shellPolicy?.cursorApplyNamed(name)
        requestCursorFrame()
    }

    private func applyCursorIntent(_ intent: CursorIntent) {
        guard intent != appliedCursorIntent else { return }
        switch intent {
        case .named(let name):
            applyNamedCursor(name)
        case .client:
            if cursorFromXwayland {
                _ = nucleus_compositor_xwm_reapply_cursor()
            } else if let compositor = RouterHost.shared.runtime?.compositor {
                _ = PointerCursorSurface.reapplyCurrent(from: compositor)
            }
            requestCursorFrame()
        }
        appliedCursorIntent = intent
    }

    private func requestCursorFrame(
        previousX: Double? = nil,
        previousY: Double? = nil
    ) {
        RenderBridge.requestCursorFrame(
            previousX: previousX,
            previousY: previousY)
    }

    // MARK: - interactive move/resize grab

    private func startRect(from r: (x: Double, y: Double, w: Double, h: Double)) -> WireWindowRect {
        var rect = WireWindowRect()
        rect.x = r.x
        rect.y = r.y
        rect.width = UInt32(max(1, r.w))
        rect.height = UInt32(max(1, r.h))
        return rect
    }

    private func beginInteractiveMoveFromChrome(windowID: UInt64) {
        guard windowID != 0, let wd = windowDriver, wd.canInteract(windowId: windowID) else { return }
        raiseWindow(windowID)
        let tile = NucleusCompositorServer.shared.window(id: windowID)?.tileEdges
        let hadTile = tile.map { $0.left || $0.right || $0.top || $0.bottom } ?? false
        guard let presented = RouterHost.shared.feeder?.presentedWindow(windowID: windowID)?.frame,
              let r = wd.beginDirectManipulation(windowId: windowID, presented: presented)
        else { return }
        // Drag start un-tiles so the client redraws full decorations.
        if hadTile { wd.configureInteractive(windowId: windowID, resizing: false) }
        WindowManager.shared.seedInteractiveStartContext(
            windowID: windowID, cursorX: cursorX, cursorY: cursorY, startRect: startRect(from: r))
        WindowManager.shared.beginInteractiveMove(windowID: windowID, serial: 0)
        clearPointerFocusSurface()
        applyNamedCursor("grabbing")
    }

    private func beginInteractiveResizeFromChrome(windowID: UInt64, edges: UInt32) {
        guard edges != 0, windowID != 0, let wd = windowDriver, wd.canInteract(windowId: windowID) else { return }
        raiseWindow(windowID)
        guard let presented = RouterHost.shared.feeder?.presentedWindow(windowID: windowID)?.frame,
              let r = wd.beginDirectManipulation(windowId: windowID, presented: presented)
        else { return }
        var re = WireResizeEdges()
        re.left = edges & 1 != 0
        re.right = edges & 2 != 0
        re.top = edges & 4 != 0
        re.bottom = edges & 8 != 0
        WindowManager.shared.seedInteractiveStartContext(
            windowID: windowID, cursorX: cursorX, cursorY: cursorY, startRect: startRect(from: r))
        WindowManager.shared.beginInteractiveResize(windowID: windowID, serial: 0, edges: re)
        wd.configureInteractive(windowId: windowID, resizing: true)
        clearPointerFocusSurface()
    }

    private func updateInteractiveGrab() {
        guard let update = try? WindowManager.shared.updateInteractiveGrab(cursorX: cursorX, cursorY: cursorY)
        else { return }
        let windowID = update.windowId
        let previousRect = WindowManager.shared.server
            .window(id: windowID)?.currentRect()
        if update.needsResizeConfigure {
            // Keep presenting the last client-committed buffer at its native
            // logical size. The new frame lands atomically with the client's
            // acked configure instead of stretching stale pixels under the drag.
            windowDriver?.configureInteractive(
                windowId: windowID, resizing: true, targetRect: update.rect)
        } else {
            windowDriver?.previewInteractiveRect(
                windowId: windowID, x: update.rect.x, y: update.rect.y,
                w: Double(update.rect.width), h: Double(update.rect.height))
        }
        RenderBridge.requestFrame(
            forWindowID: windowID,
            includingPreviousRect: previousRect)
    }

    private func finishInteractiveGrab(timeMsec: UInt32) {
        let finalResize = try? WindowManager.shared.updateInteractiveGrab(
            cursorX: cursorX, cursorY: cursorY)
        WindowManager.shared.endInteractiveGrab()
        if let finalResize, finalResize.needsResizeConfigure {
            // Clear xdg_toplevel.state.resizing and carry the final requested
            // geometry in the same configure cycle.
            windowDriver?.configureInteractive(
                windowId: finalResize.windowId,
                resizing: false,
                targetRect: finalResize.rect)
        }
        // Re-run targeting at the current cursor so focus/cursor settle post-grab.
        var motion = WireEventRecord()
        motion.kind = .mouseMoved
        motion.flags = streamFlags
        motion.timestampNs = UInt64(timeMsec) &* 1_000_000
        motion.x = cursorX
        motion.y = cursorY
        processCursorMotion(motion)
    }

    // MARK: - state cache + helpers

    private func cacheState(_ s: WireEventStateSnapshot) {
        cursorX = s.cursorX
        cursorY = s.cursorY
        streamFlags = s.flags
        leftButtonDown = s.leftButtonDown
        rightButtonDown = s.rightButtonDown
        otherButtonCount = s.otherButtonCount
    }

    private func pointerBounds() -> WirePointerBounds {
        var b = WirePointerBounds()
        if let r = NucleusCompositorServer.shared.layout.desktopBounds() {
            b.minX = r.x
            b.minY = r.y
            b.maxX = r.maxX - 1
            b.maxY = r.maxY - 1
        }
        return b
    }

    private func isKey(_ k: WireEventKind) -> Bool { k == .keyDown || k == .keyUp }

    private func isMotion(_ k: WireEventKind) -> Bool {
        k == .mouseMoved || k == .leftMouseDragged || k == .rightMouseDragged || k == .otherMouseDragged
    }

    private func isButtonDown(_ k: WireEventKind) -> Bool {
        k == .leftMouseDown || k == .rightMouseDown || k == .otherMouseDown
    }

    private func msec(_ e: WireEventRecord) -> UInt32 {
        UInt32(truncatingIfNeeded: e.timestampNs / 1_000_000)
    }

    /// Linux Ctrl+Alt+Fn → VT number (F1..F10 → 1..10, F11/F12 → 11/12).
    private func vtForEvdevKey(_ keycode: UInt32) -> Int32? {
        if keycode >= 59 && keycode <= 68 { return Int32(keycode - 58) }
        if keycode == 87 { return 11 }
        if keycode == 88 { return 12 }
        return nil
    }
}

extension InputDispatch: CompositorInputControl {
    func displayWillRemove(hasFallbackDisplay: Bool) {
        clearPointerFocus()
        if !hasFallbackDisplay { clearKeyboardFocus() }
    }

    func currentPressedEvdevKeys() -> [UInt32] { xkb.pressedEvdevKeys() }

    /// Run a window-menu verb the overlay reported to the shell. Reached from the
    /// shell's overlay-publication conformer through `NucleusCompositorServer.shared.inputControl`.
    func windowMenuSelected(windowID: UInt64, verb: Int32) {
        guard windowID != 0, let runtime = RouterHost.shared.runtime else { return }
        let driver = runtime.windowDriver
        let surfaceID = UInt32(truncatingIfNeeded: driver.rootSurface(forWindowId: windowID))
        switch verb {
        case 0:
            if surfaceID != 0 { driver.close(surfaceId: surfaceID) }
        case 1:
            if driver.minimize(windowId: windowID) {
                clearKeyboardFocus(ifWindow: windowID)
                RenderBridge.requestFrame(
                    forWindowID: windowID)
            }
        case 2:
            if surfaceID != 0 { driver.toggleMaximize(surfaceId: surfaceID) }
        case 3:
            if surfaceID != 0 { driver.toggleFullscreen(surfaceId: surfaceID) }
        case 4:
            beginInteractiveMove(windowID: windowID)
        case 5:
            beginInteractiveResize(windowID: windowID, edges: 2 | 8)
        default:
            break
        }
    }
}
