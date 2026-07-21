import NucleusCompositorServer
import NucleusCompositorServerTypes
import NucleusCompositorWindowManager
import Glibc
@MainActor
extension InputDispatch {
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
        if target != 0 { seatDelivery.pointerFrame(surfaceID: target) }
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
        seatDelivery.keyboardLeave(surfaceID: old)
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
        host.server.events.resetInputState()
        streamFlags = 0
        leftButtonDown = false
        rightButtonDown = false
        otherButtonCount = 0
        let target = keyboardFocusID()
        if target != 0 {
            seatDelivery.keyboardModifiers(surfaceID: target, depressed: 0, latched: 0, locked: 0, group: 0)
        }
        seatFocus.resetPointerButtons()
        host.windowManager.endInteractiveGrab()
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

    package func cacheState(_ s: WireEventStateSnapshot) {
        cursorX = s.cursorX
        cursorY = s.cursorY
        streamFlags = s.flags
        leftButtonDown = s.leftButtonDown
        rightButtonDown = s.rightButtonDown
        otherButtonCount = s.otherButtonCount
    }

    package func pointerBounds() -> WirePointerBounds {
        var b = WirePointerBounds()
        if let r = host.server.layout.desktopBounds() {
            b.minX = r.x
            b.minY = r.y
            b.maxX = r.maxX - 1
            b.maxY = r.maxY - 1
        }
        return b
    }

    package func isKey(_ k: WireEventKind) -> Bool { k == .keyDown || k == .keyUp }

    package func isMotion(_ k: WireEventKind) -> Bool {
        k == .mouseMoved || k == .leftMouseDragged || k == .rightMouseDragged || k == .otherMouseDragged
    }

    package func isButtonDown(_ k: WireEventKind) -> Bool {
        k == .leftMouseDown || k == .rightMouseDown || k == .otherMouseDown
    }

    package func msec(_ e: WireEventRecord) -> UInt32 {
        UInt32(truncatingIfNeeded: e.timestampNs / 1_000_000)
    }

    /// Linux Ctrl+Alt+Fn → VT number (F1..F10 → 1..10, F11/F12 → 11/12).
    package func vtForEvdevKey(_ keycode: UInt32) -> Int32? {
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
        guard windowID != 0, let runtime = host.runtime else { return }
        let driver = runtime.windowDriver
        let surfaceID = UInt32(truncatingIfNeeded: driver.rootSurface(forWindowId: windowID))
        switch verb {
        case 0:
            if surfaceID != 0 { driver.close(surfaceId: surfaceID) }
        case 1:
            if driver.minimize(windowId: windowID) {
                clearKeyboardFocus(ifWindow: windowID)
                RenderBridge.requestFrame(
                    server: host.server,
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
