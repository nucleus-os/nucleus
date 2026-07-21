import NucleusCompositorServer
import NucleusCompositorServerTypes
import NucleusCompositorWindowManager
import Glibc
@MainActor
extension InputDispatch {
    package func handleTouch(_ event: WireEventRecord) {
        let id = Int32(bitPattern: UInt32(truncatingIfNeeded: event.data0))
        switch event.kind {
        case .touchDown:
            let hit = routerHitTest(host: host, sx: event.x, sy: event.y)
            guard hit.surfaceId != 0, !lockBlocks(hit.surfaceId) else { return }
            touchGrabs[id] = TouchGrab(
                surfaceID: hit.surfaceId,
                localOffsetX: hit.localX - event.x,
                localOffsetY: hit.localY - event.y)
            seatDelivery.touchDown(
                surfaceID: hit.surfaceId, timeMsec: msec(event), id: id,
                x: hit.localX, y: hit.localY)
        case .touchMotion:
            if host.runtime?.dataDevice.dragActive == true {
                let hit = routerHitTest(host: host, sx: event.x, sy: event.y)
                _ = host.runtime?.dataDevice.dragMotion(
                    surfaceID: hit.surfaceId,
                    x: hit.localX,
                    y: hit.localY,
                    timeMsec: msec(event))
                return
            }
            guard let grab = touchGrabs[id], !lockBlocks(grab.surfaceID) else { return }
            seatDelivery.touchMotion(
                surfaceID: grab.surfaceID, timeMsec: msec(event), id: id,
                x: event.x + grab.localOffsetX, y: event.y + grab.localOffsetY)
        case .touchUp:
            guard let grab = touchGrabs.removeValue(forKey: id), !lockBlocks(grab.surfaceID) else { return }
            seatDelivery.touchUp(surfaceID: grab.surfaceID, timeMsec: msec(event), id: id)
            if touchGrabs.isEmpty {
                _ = host.runtime?.dataDevice.dropActiveDrag()
            }
        case .touchFrame:
            for surfaceID in Set(touchGrabs.values.map(\.surfaceID)) {
                seatDelivery.touchFrame(surfaceID: surfaceID)
            }
        case .touchCancel:
            for surfaceID in Set(touchGrabs.values.map(\.surfaceID)) {
                seatDelivery.touchCancel(surfaceID: surfaceID)
            }
            touchGrabs.removeAll(keepingCapacity: true)
            host.runtime?.dataDevice.cancelActiveDrag(
                notifySource: true)
        default:
            break
        }
    }

    // MARK: - shortcut tap (session keybind policy)

    package enum ShortcutTapResult {
        case pass
        case suppress
        case replace(WireEventRecord)
        case dispatch(Result)
    }

    package func runShortcutTap(_ record: inout WireEventRecord) -> ShortcutTapResult {
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
        if keyboardSurface != 0 && seatDelivery.isInhibited(surfaceID: keyboardSurface) {
            return .pass
        }

        // Session-policy layer (the shell, via the inverted seam).
        guard let shell = host.server.shellPolicy else { return .pass }
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
    package func executeDeferredAction(action: UInt8, value: UInt32) {
        switch action {
        case 1:  // close_focused
            let surface = keyboardFocusID()
            if surface != 0 { windowDriver?.close(surfaceId: UInt32(truncatingIfNeeded: surface)) }
        case 3:  // toggle_hotkey
            host.server.shellPolicy?.toggleHotkey()
            requestOverlayFrame()
        case 4:  // dismiss_hotkey
            host.server.shellPolicy?.dismissHotkey()
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
            RenderBridge.requestFrame(server: host.server, outputId: 0)
        case 9:  // activate_workspace (value: 1-based index)
            activateWorkspace(index: value)
        case 10:  // move_window_to_workspace (value: 1-based index)
            moveFocusedWindowToWorkspace(index: value)
        default:
            break
        }
    }

    // MARK: - keyboard

    package func handleKey(_ event: WireEventRecord) -> Result {
        let keycode = UInt32(truncatingIfNeeded: event.data0)
        let pressed = event.kind == .keyDown

        // The overlay holds the keyboard grab whenever it wants keys — an open
        // window menu, or a focused text field in its own scene. Every key is
        // consumed so the client below stays frozen. Suppressed while locked:
        // the lock screen owns the keyboard, and overlay UI must not be drivable
        // behind it.
        if !lockActive(), host.server.shellPolicy?.overlaySceneWantsKeyboard() ?? false {
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
        if !seatDelivery.isInhibited(surfaceID: target) {
            let policy = clientPolicy.policy(forSurfaceID: target)
            let commandActive = event.flags & EventFlagBit.command != 0
            if clientPolicy.handleClientKey(
                surfaceID: target, keycode: keycode, pressed: pressed, timeMsec: timeMsec,
                commandActive: commandActive, policy: policy,
                physical: modsAfter, masks: xkb.modifierMasks())
            {
                return .delivered
            }
        }

        seatDelivery.keyboardKey(
            surfaceID: target, timeMsec: timeMsec, keycode: keycode, keyState: pressed ? 1 : 0)
        InputLatencyProbe.markDelivery(.keyboardKey)
        seatDelivery.keyboardModifiers(
            surfaceID: target, depressed: modsAfter.depressed, latched: modsAfter.latched,
            locked: modsAfter.locked, group: modsAfter.group)
        return .delivered
    }

    package func updateKeyboardStateForEvent(_ event: inout WireEventRecord) {
        guard isKey(event.kind) else { return }
        let keycode = UInt32(truncatingIfNeeded: event.data0)
        let pressed = event.kind == .keyDown
        let seatKeyCount: UInt32? = event.data2 == UInt64.max ? nil : UInt32(truncatingIfNeeded: event.data2)
        xkb.updateKey(evdevKeycode: keycode, pressed: pressed, seatKeyCount: seatKeyCount)
        event.flags = xkb.flagsRaw()
        streamFlags = event.flags
    }

    // MARK: - pointer

}
