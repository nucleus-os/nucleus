import NucleusCompositorOverlayScene
import NucleusCompositorOverlayTypes
import NucleusCompositorServer

@MainActor
public protocol ShellPolicyHost: AnyObject {
    func keybindDispatch(
        keycode: UInt32,
        modifiers: UInt64,
        pressed: Bool
    ) -> KeybindDecision
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
public final class ShellPolicyService: ShellPolicyHost, CompositorShellPolicy {
    private let keybinds: KeybindService
    private let launcher: LauncherService
    private let idle: IdlePolicy
    private let cursorTheme: CursorThemeService
    private let bezel: BezelService
    private let notifications: NotificationService
    private let overlayScene: OverlaySceneRuntime

    public init(
        keybinds: KeybindService,
        launcher: LauncherService,
        idle: IdlePolicy,
        cursorTheme: CursorThemeService,
        bezel: BezelService,
        notifications: NotificationService,
        overlayScene: OverlaySceneRuntime
    ) {
        self.keybinds = keybinds
        self.launcher = launcher
        self.idle = idle
        self.cursorTheme = cursorTheme
        self.bezel = bezel
        self.notifications = notifications
        self.overlayScene = overlayScene
    }

    public func keybindDispatch(
        keycode: UInt32,
        modifiers: UInt64,
        pressed: Bool
    ) -> KeybindDecision {
        keybinds.bridgeDispatch(
            keycode: keycode,
            modifierBits: modifiers,
            pressed: pressed)
    }

    public func dispatchKeybind(
        keycode: UInt32,
        modifiers: UInt64,
        pressed: Bool
    ) -> KeybindOutcome {
        let decision = keybindDispatch(
            keycode: keycode,
            modifiers: modifiers,
            pressed: pressed)
        let kind: KeybindOutcome.Kind = switch decision.kind {
        case .consume: .consume
        case .deferred: .deferred
        default: .pass
        }
        return KeybindOutcome(
            kind: kind,
            action: decision.action.rawValue,
            value: decision.value)
    }

    public func cursorApplyDefault() {
        cursorTheme.applyDefault()
    }

    public func cursorApplyNamed(_ name: String) {
        cursorTheme.applyNamed(name)
    }

    public func toggleHotkey() {
        bezel.toggleHotkey()
    }

    public func dismissHotkey() {
        bezel.dismissHotkey()
    }

    public func overlayActive() -> Bool {
        bezel.isHotkeyVisible()
            || notifications.notificationCount() > 0
            || bezel.hasCommittedContent()
            || overlayScene.menuVisible()
    }

    public func overlaySceneMenuVisible() -> Bool {
        overlayScene.menuVisible()
    }

    public func overlaySceneWantsKeyboard() -> Bool {
        overlayScene.wantsKeyboard()
    }

    public func overlayPointer(
        x: Float,
        y: Float,
        kind: UInt32,
        button: UInt32,
        timestampNs: UInt64
    ) -> UInt64 {
        guard let inputKind = InputKind(rawValue: kind) else { return 0 }
        return packedOverlayResult(bezel.dispatchInput(.init(
            kind: inputKind,
            button: button,
            x: x,
            y: y,
            scrollX: 0,
            scrollY: 0,
            keycode: 0,
            modifiers: 0,
            timestampNs: timestampNs)))
    }

    public func overlayKey(
        keycode: UInt32,
        modifiers: UInt32,
        text: String?,
        kind: UInt32,
        timestampNs: UInt64
    ) -> UInt64 {
        guard let inputKind = InputKind(rawValue: kind) else { return 0 }
        return packedOverlayResult(bezel.dispatchInput(.init(
            kind: inputKind,
            button: 0,
            x: 0,
            y: 0,
            scrollX: 0,
            scrollY: 0,
            keycode: keycode,
            modifiers: modifiers,
            text: text,
            timestampNs: timestampNs)))
    }

    public func overlaySceneShowWindowMenu(
        windowID: UInt64,
        x: Double,
        y: Double,
        capabilities: UInt32
    ) {
        overlayScene.showWindowMenu(
            windowID: windowID,
            x: x,
            y: y,
            capabilities: capabilities)
    }

    public func launcherPlayScreenshotSound() {
        launcher.playScreenshotSound()
    }

    public func idleRegisterNotification(id: UInt64, timeoutMS: UInt32) {
        idle.registerNotification(id: id, timeoutMS: timeoutMS)
    }

    public func idleUnregisterNotification(id: UInt64) {
        idle.unregisterNotification(id: id)
    }

    public func idleInhibitInc() {
        idle.inhibitInc()
    }

    public func idleInhibitDec() {
        idle.inhibitDec()
    }

    public func idleNoteInput(nowNS: UInt64) throws(HostCallError) -> [UInt64] {
        idle.noteInput(nowNS: nowNS, max: .max)
    }

    public func idleNextDeadlineNS(
        nowNS: UInt64
    ) throws(HostCallError) -> UInt64? {
        idle.nextDeadlineNS(nowNS: nowNS)
    }

    public func idleTick(nowNS: UInt64) throws(HostCallError) -> [UInt64] {
        idle.tick(nowNS: nowNS, max: .max)
    }
}

private func packedOverlayResult(_ result: InputResult) -> UInt64 {
    var bits: UInt32 = 0
    if result.consumed { bits |= 1 }
    if result.cursor == .pointer { bits |= 2 }
    if result.wantsFrame { bits |= 4 }
    return UInt64(bits)
}
