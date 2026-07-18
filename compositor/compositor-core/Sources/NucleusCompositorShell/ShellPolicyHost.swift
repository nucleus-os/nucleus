import NucleusCompositorOverlayTypes
import NucleusCompositorOverlayScene
import NucleusCompositorServer

/// Conform the shell policy service to the compositor's inverted `shellPolicy`
/// seam (defined in `.server`), mapping the wire `KeybindDecision` to the
/// compositor-owned `KeybindOutcome`. The shell injects this into
/// `NucleusCompositorServer.shared.shellPolicy` at startup so the input dispatch reaches
/// keybind policy without importing `.shell` (which the area DAG forbids).
extension ShellPolicyService: CompositorShellPolicy {
    public func dispatchKeybind(keycode: UInt32, modifiers: UInt64, pressed: Bool) -> KeybindOutcome {
        let decision: KeybindDecision = keybindDispatch(
            keycode: keycode, modifiers: modifiers, pressed: pressed)
        let kind: KeybindOutcome.Kind = switch decision.kind {
        case .consume: .consume
        case .deferred: .deferred
        default: .pass
        }
        return KeybindOutcome(kind: kind, action: decision.action.rawValue, value: decision.value)
    }

    // The cursor/bezel owners are in this module; the overlay-scene owners
    // are in NucleusCompositorOverlayScene (a NucleusCompositorShell dep). The input dispatch reaches
    // both through this conformer (installed into NucleusCompositorServer.shared.shellPolicy).
    public func cursorApplyDefault() { nucleus_compositor_cursor_apply_default() }
    public func cursorApplyNamed(_ name: String) {
        name.withCString { nucleus_compositor_cursor_apply_named($0) }
    }
    public func toggleHotkey() { nucleus_compositor_shell_toggle_hotkey() }
    public func dismissHotkey() { nucleus_compositor_shell_dismiss_hotkey() }
    public func overlayActive() -> Bool { nucleus_compositor_shell_overlay_active() }
    public func overlaySceneMenuVisible() -> Bool { nucleus_compositor_overlay_scene_menu_visible() }
    public func overlaySceneWantsKeyboard() -> Bool { nucleus_compositor_overlay_scene_wants_keyboard() }
    public func overlayPointer(x: Float, y: Float, kind: UInt32, button: UInt32, timestampNs: UInt64) -> UInt64 {
        nucleus_compositor_shell_overlay_pointer(x, y, kind, button, timestampNs)
    }
    public func overlayKey(
        keycode: UInt32, modifiers: UInt32, text: String?, kind: UInt32, timestampNs: UInt64
    ) -> UInt64 {
        nucleus_compositor_shell_overlay_key(keycode, modifiers, text, kind, timestampNs)
    }
    public func overlaySceneShowWindowMenu(windowID: UInt64, x: Double, y: Double, capabilities: UInt32) {
        nucleus_compositor_overlay_scene_show_window_menu(windowID, x, y, capabilities)
    }
}

@MainActor
public protocol ShellPolicyHost: AnyObject {
    func appearanceSetColorScheme(value: UInt32)
    func appearanceSetContrast(value: UInt32)
    func appearanceSnapshot(
        colorScheme: UnsafeMutablePointer<UInt32>?,
        contrast: UnsafeMutablePointer<UInt32>?,
        epoch: UnsafeMutablePointer<UInt64>?
    )
    func keybindDispatch(keycode: UInt32, modifiers: UInt64, pressed: Bool) -> NucleusCompositorOverlayTypes.KeybindDecision
    func launcherPlayScreenshotSound()
    func idleRegisterNotification(id: UInt64, timeoutMS: UInt32)
    func idleUnregisterNotification(id: UInt64)
    func idleInhibitInc()
    func idleInhibitDec()
    func idleNoteInput(nowNS: UInt64) throws(HostCallError) -> [UInt64]
    func idleNextDeadlineNS(nowNS: UInt64) throws(HostCallError) -> UInt64?
    func idleTick(nowNS: UInt64) throws(HostCallError) -> [UInt64]
}

@MainActor
public final class ShellPolicyService: ShellPolicyHost {
    public static let shared = ShellPolicyService()

    private init() {}

    public func appearanceSetColorScheme(value: UInt32) {
        AppearancePortal.shared.setColorScheme(value)
    }

    public func appearanceSetContrast(value: UInt32) {
        AppearancePortal.shared.setContrast(value)
    }

    public func appearanceSnapshot(
        colorScheme: UnsafeMutablePointer<UInt32>?,
        contrast: UnsafeMutablePointer<UInt32>?,
        epoch: UnsafeMutablePointer<UInt64>?
    ) {
        let snapshot = AppearancePortal.shared.snapshot()
        colorScheme?.pointee = snapshot.0
        contrast?.pointee = snapshot.1
        epoch?.pointee = snapshot.2
    }

    public func keybindDispatch(keycode: UInt32, modifiers: UInt64, pressed: Bool) -> NucleusCompositorOverlayTypes.KeybindDecision {
        KeybindService.bridgeDispatch(keycode: keycode, modifierBits: modifiers, pressed: pressed)
    }

    public func launcherPlayScreenshotSound() {
        LauncherService.shared.playScreenshotSound()
    }

    public func idleRegisterNotification(id: UInt64, timeoutMS: UInt32) {
        IdlePolicy.shared.registerNotification(id: id, timeoutMS: timeoutMS)
    }

    public func idleUnregisterNotification(id: UInt64) {
        IdlePolicy.shared.unregisterNotification(id: id)
    }

    public func idleInhibitInc() {
        IdlePolicy.shared.inhibitInc()
    }

    public func idleInhibitDec() {
        IdlePolicy.shared.inhibitDec()
    }

    public func idleNoteInput(nowNS: UInt64) throws(HostCallError) -> [UInt64] {
        IdlePolicy.shared.noteInput(nowNS: nowNS, max: Int.max)
    }

    public func idleNextDeadlineNS(nowNS: UInt64) throws(HostCallError) -> UInt64? {
        IdlePolicy.shared.nextDeadlineNS(nowNS: nowNS)
    }

    public func idleTick(nowNS: UInt64) throws(HostCallError) -> [UInt64] {
        IdlePolicy.shared.tick(nowNS: nowNS, max: Int.max)
    }
}
