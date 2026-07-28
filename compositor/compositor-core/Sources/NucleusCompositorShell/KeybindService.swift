import NucleusCompositorOverlayTypes
public import NucleusCompositorWindowManager
public import NucleusConfig

/// Compositor session-policy keybind table.
///
/// Apple-shape analog: loginwindow/SkyLight's global hotkey policy layered on
/// top of WindowServer event taps. The reactor's event tap forwards every
/// keyboard event to its runtime-owned `KeybindService` and acts on the
/// returned `Dispatch`.
///
/// The table comes from configuration. Chords and actions are the shared
/// `NucleusConfig` vocabulary rather than types private to this service,
/// because the control socket has to name the same operations a binding names —
/// defining "close the focused window" twice would guarantee the two drift.
@MainActor
public final class KeybindService {
    public enum Phase: Sendable {
        case down
        case up
    }

    /// Wire ABI crossed to the overlay. Values are stable; a retired case
    /// keeps its slot rather than letting a later case reuse the number.
    private enum KeybindAction: UInt8 {
        case none = 0
        case closeFocused = 1
        case toggleHotkey = 3
        case dismissHotkey = 4
        // 5: RESERVED (formerly wallpaper; wire ABI slot kept stable).
        case windowMenu = 6
        case tile = 7
        case backdropChanged = 8
        case activateWorkspace = 9
        case moveWindowToWorkspace = 10
    }

    public enum Dispatch: Sendable {
        case pass
        case consume
        case deferred(DeferredAction)
    }

    enum Resolution: Sendable {
        case pass
        case consume
        case action(BindAction)
    }

    public struct DeferredAction: Sendable {
        public let kind: UInt8
        public let value: UInt32
    }

    private var bindings: [KeyChord: BindAction]
    private var globallyCapturedKeys: Set<UInt32> = []
    private let launcher: LauncherService
    private unowned let windowManager: WindowManager

    public init(
        launcher: LauncherService,
        windowManager: WindowManager,
        binds: [KeyBind] = DefaultBinds.table
    ) {
        self.launcher = launcher
        self.windowManager = windowManager
        self.bindings = Self.table(from: binds)
    }

    /// Adopt a new table wholesale, as a configuration reload produces.
    ///
    /// Keys captured by the outgoing table are released: a chord that is no
    /// longer bound must not swallow its own key-up and leave the client that
    /// now owns it holding a key down forever.
    public func updateBinds(_ binds: [KeyBind]) {
        bindings = Self.table(from: binds)
        globallyCapturedKeys.removeAll(keepingCapacity: true)
    }

    /// Later entries win, so a file that binds the same chord twice takes its
    /// last word rather than an arbitrary one.
    private static func table(from binds: [KeyBind]) -> [KeyChord: BindAction] {
        var table: [KeyChord: BindAction] = [:]
        for bind in binds { table[bind.keys] = bind.action }
        return table
    }

    public func dispatch(
        keycode: UInt32, modifiers: KeyModifiers, phase: Phase
    ) -> Dispatch {
        switch resolve(keycode: keycode, modifiers: modifiers, phase: phase) {
        case .pass:
            return .pass
        case .consume:
            return .consume
        case .action(let action):
            return run(action)
        }
    }

    func resolve(
        keycode: UInt32, modifiers: KeyModifiers, phase: Phase
    ) -> Resolution {
        if Self.isModifierKey(keycode) {
            return .pass
        }

        guard phase == .down else {
            if globallyCapturedKeys.remove(keycode) != nil {
                return .consume
            }
            return .pass
        }

        let chord = KeyChord(modifiers: modifiers, keyCode: keycode)
        if let action = bindings[chord] {
            globallyCapturedKeys.insert(keycode)
            return .action(action)
        }

        return .pass
    }

    private static func isModifierKey(_ keycode: UInt32) -> Bool {
        switch keycode {
        case 29, 42, 54, 56, 58, 97, 100, 125, 126:
            return true
        default:
            return false
        }
    }

    /// Run an action that did not arrive from a keypress.
    ///
    /// The control socket reaches the same executor a binding does, so a
    /// command and a chord cannot diverge in what they actually perform.
    public func perform(_ action: BindAction) -> Dispatch {
        run(action)
    }

    private func run(_ action: BindAction) -> Dispatch {
        switch action {
        case .launch(let appIDs, let command):
            _ = launcher.launchPreferred(ids: appIDs, fallback: command)
            return .consume

        case .closeWindow:
            return .deferred(DeferredAction(
                kind: KeybindAction.closeFocused.rawValue, value: 0))
        case .showWindowMenu:
            return .deferred(DeferredAction(
                kind: KeybindAction.windowMenu.rawValue, value: 0))
        case .toggleHotkeyOverlay:
            return .deferred(DeferredAction(
                kind: KeybindAction.toggleHotkey.rawValue, value: 0))
        case .dismissHotkeyOverlay:
            return .deferred(DeferredAction(
                kind: KeybindAction.dismissHotkey.rawValue, value: 0))
        case .tile(let direction):
            return .deferred(DeferredAction(
                kind: KeybindAction.tile.rawValue,
                value: Self.wireValue(direction)))
        case .adjustBackdropIntensity(let delta):
            let next = windowManager.backdropResolver.dynamics
                .target.resolvedIntensity + Float(delta)
            _ = windowManager.backdropResolver.dynamics.setIntensity(next)
            return .deferred(DeferredAction(
                kind: KeybindAction.backdropChanged.rawValue, value: 0))
        case .activateWorkspace(let index):
            return .deferred(DeferredAction(
                kind: KeybindAction.activateWorkspace.rawValue, value: index))
        case .moveWindowToWorkspace(let index):
            return .deferred(DeferredAction(
                kind: KeybindAction.moveWindowToWorkspace.rawValue,
                value: index))
        }
    }

    /// Mirrors `NucleusCompositorWindowManager.TileCommand`. The executor
    /// drives the focused window's Swift role with this scalar.
    static func wireValue(_ direction: TileDirection) -> UInt32 {
        switch direction {
        case .left: 1
        case .right: 2
        case .top: 3
        case .bottom: 4
        case .topLeft: 5
        case .topRight: 6
        case .bottomLeft: 7
        case .bottomRight: 8
        case .maximize: 9
        }
    }
}

extension KeybindService {
    /// Converts the reactor's raw modifier bits into the shell's typed keybind
    /// decision used by `ShellPolicyService`.
    func bridgeDispatch(
        keycode: UInt32,
        modifierBits: UInt64,
        pressed: Bool
    ) -> NucleusCompositorOverlayTypes.KeybindDecision {
        let modifiers = Self.decode(modifierBits: modifierBits)
        let phase: Phase = pressed ? .down : .up
        let decision = dispatch(
            keycode: keycode, modifiers: modifiers, phase: phase)

        switch decision {
        case .pass:
            return NucleusCompositorOverlayTypes.KeybindDecision(
                kind: .pass, action: .none, reserved: 0, value: 0)
        case .consume:
            return NucleusCompositorOverlayTypes.KeybindDecision(
                kind: .consume, action: .none, reserved: 0, value: 0)
        case .deferred(let action):
            return NucleusCompositorOverlayTypes.KeybindDecision(
                kind: .deferred,
                action: NucleusCompositorOverlayTypes.KeybindAction(
                    rawValue: action.kind) ?? .none,
                reserved: 0,
                value: action.value)
        }
    }

    /// The reactor's `EventFlags` is a packed u64 mirroring `CGEventFlags`:
    /// shift=bit17, control=bit18, alternate=bit19, command=bit20. Decode
    /// to the shared `KeyModifiers` option set.
    static func decode(modifierBits: UInt64) -> KeyModifiers {
        var flags: KeyModifiers = []
        if (modifierBits & (1 << 17)) != 0 { flags.insert(.shift) }
        if (modifierBits & (1 << 18)) != 0 { flags.insert(.control) }
        if (modifierBits & (1 << 19)) != 0 { flags.insert(.alt) }
        if (modifierBits & (1 << 20)) != 0 { flags.insert(.superKey) }
        return flags
    }
}
