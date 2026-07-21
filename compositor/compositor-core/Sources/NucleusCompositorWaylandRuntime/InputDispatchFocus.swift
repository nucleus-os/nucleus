import NucleusCompositorServer
import NucleusCompositorServerTypes
import NucleusCompositorWindowManager
import Glibc
@MainActor
extension InputDispatch {
    package var seatFocus: SeatFocus { host.server.seatFocus }
    package var windowDriver: RouterWindowDriver? { host.runtime?.windowDriver }

    package func pointerFocusID() -> UInt64 { seatFocus.pointerSurfaceID }
    package func keyboardFocusID() -> UInt64 { seatFocus.keyboardSurfaceID }

    // MARK: - session-lock gate

    package func lockActive() -> Bool {
        host.sessionLockGate.isActive()
    }

    /// While locked, focus/events may only land on a lock surface (source 4); an
    /// unowned surface (0) fails closed.
    package func lockBlocks(_ surfaceID: UInt64) -> Bool {
        if !lockActive() { return false }
        if surfaceID == 0 { return true }
        let source = windowDriver?.windowSource(forSurfaceId: UInt32(truncatingIfNeeded: surfaceID)) ?? 0
        return source != 4
    }

    // MARK: - focus management

    package func setPointerFocusSurface(_ surfaceID: UInt64, sx: Double, sy: Double) {
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
        if old != 0 { seatDelivery.pointerLeave(surfaceID: old) }
        if surfaceID != 0 { seatDelivery.pointerEnter(surfaceID: surfaceID, x: sx, y: sy) }
    }

    package func clearPointerFocusSurface() {
        let old = pointerFocusID()
        if old == 0 { return }
        seatFocus.clearPointerFocus()
        seatDelivery.pointerLeave(surfaceID: old)
    }

    package func setKeyboardFocusSurface(_ surfaceID: UInt64) {
        if lockBlocks(surfaceID) { return }
        let old = keyboardFocusID()
        if old == surfaceID { return }
        seatFocus.setKeyboardFocus(surfaceID: surfaceID)
        if surfaceID != 0, let wd = windowDriver {
            let windowID = wd.windowId(forSurfaceId: UInt32(truncatingIfNeeded: surfaceID))
            if windowID != 0 {
                host.server.windows.focus(id: windowID)
            }
        }
        if old != 0 { seatDelivery.keyboardLeave(surfaceID: old) }
        if surfaceID != 0 { seatDelivery.keyboardEnter(surfaceID: surfaceID) }
        // Re-drive xdg activation for the focus change (model focus + configure; the
        // seat enter/leave above already delivered the wl_keyboard transition).
        windowDriver?.publishKeyboardFocus(
            oldSurfaceId: UInt32(truncatingIfNeeded: old),
            newSurfaceId: UInt32(truncatingIfNeeded: surfaceID))
    }

}
