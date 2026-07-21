import NucleusCompositorServer
import NucleusCompositorServerTypes
import NucleusCompositorWindowManager
import Glibc
@MainActor
extension InputDispatch {
    package func processCursorMotion(_ event: WireEventRecord) {
        // An active interactive move/resize grab owns motion until release.
        if host.windowManager.interactiveGrabActive() {
            updateInteractiveGrab()
            return
        }
        let sx = cursorX
        let sy = cursorY
        let hit = routerHitTest(host: host, sx: sx, sy: sy)
        if host.runtime?.dataDevice.dragMotion(
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
            cursorFromXwayland = host.xwaylandHost?.xwm?.applyCurrentCursor() ?? false
            appliedCursorIntent = cursorFromXwayland ? .client : nil
        } else if decision.shouldRestoreDefaultCursor {
            // Pointer focus left the client: drop its set_cursor binding so its later
            // surface commits no longer control the cursor, then restore the default.
            host.pointerCursorSurface.clear()
            host.server.shellPolicy?.cursorApplyDefault()
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
            if host.server.shellPolicy?.overlayActive() ?? false {
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
                clientOwnsCursor: host.pointerCursorSurface.surfaceId != 0 || cursorFromXwayland,
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

    package func handleMouseButton(_ event: WireEventRecord) {
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

        if host.runtime?.dataDevice.dragActive == true {
            deliverPointerButton(event, button: button, down: down)
            if !down, seatFocus.buttonCount == 0 {
                _ = host.runtime?.dataDevice.dropActiveDrag()
            }
            return
        }

        // Shell-overlay arbitration: a button up, or any button while the overlay is
        // active, routes into the overlay first; a consumed event stops here.
        if !down || (host.server.shellPolicy?.overlayActive() ?? false) {
            let bits = dispatchOverlayPointer(kind: down ? 2 : 3, button: button, timestampNs: event.timestampNs)
            if bits & 1 != 0 { return }
        }

        // An active interactive grab consumes the button; the last release finishes it.
        if host.windowManager.interactiveGrabActive() {
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

    package func handleScroll(_ event: WireEventRecord) {
        let target = pointerFocusID()
        if target == 0 || lockBlocks(target) { return }
        let delta = Double(bitPattern: event.data0)
        let value120 = Int32(bitPattern: UInt32(truncatingIfNeeded: event.data1))
        let orientation = UInt32(truncatingIfNeeded: event.data2)
        let source = UInt32(truncatingIfNeeded: event.data3)
        seatDelivery.pointerAxis(
            surfaceID: target, timeMsec: msec(event), axis: orientation,
            delta: delta, value120: value120, source: source)
    }

    package func deliverPointerMotion(_ event: WireEventRecord, surfaceID: UInt64, sx: Double, sy: Double) {
        if lockBlocks(surfaceID) { return }
        seatDelivery.pointerMotionRaw(
            surfaceID: surfaceID, timeMsec: msec(event), surfaceX: sx, surfaceY: sy,
            dx: Double(bitPattern: event.data0), dy: Double(bitPattern: event.data1),
            dxUnaccel: Double(bitPattern: event.data2), dyUnaccel: Double(bitPattern: event.data3))
        InputLatencyProbe.markDelivery(.pointerMotion)
    }

    package func deliverPointerButton(_ event: WireEventRecord, button: UInt32, down: Bool) {
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
            serial = seatDelivery.pointerButton(
                surfaceID: target, timeMsec: msec(event), button: button, state: down ? 1 : 0)
            InputLatencyProbe.markDelivery(.pointerButton)
        }
        seatFocus.recordPointerButton(state: down ? 1 : 0, serial: serial, focusedSurfaceID: target)
    }

    /// Click-to-focus + raise-on-click: a press inside a window focuses it (unless it
    /// already holds keyboard focus) before the press is delivered.
    package func focusAndRaiseWindowUnderPointer() {
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
    package func applyPointerConstraints(_ event: inout WireEventRecord) {
        guard isMotion(event.kind) else { return }
        let surfaceID = pointerFocusID()
        if surfaceID == 0 { return }
        switch seatDelivery.pointerConstraintKind(surfaceID: surfaceID) {
        case 1:  // locked
            event.x = cursorX
            event.y = cursorY
        case 2:  // confined
            guard let rect = host.feeder?.presentedWindow(
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
}
