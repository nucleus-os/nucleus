import Foundation
import NucleusCompositorOverlayTypes
import NucleusCompositorWindowManager

/// Compositor session-policy keybind table.
///
/// Apple-shape analog: loginwindow/SkyLight's global hotkey policy layered on
/// top of WindowServer event taps. The reactor's event tap forwards every
/// keyboard event to `KeybindService.shared.dispatch` and acts on the
/// returned `Dispatch`. Window-management keybinds (tile, VT switch, exit)
/// stay in the reactor — those are not session policy.
@MainActor
public final class KeybindService {
    public static let shared = KeybindService()

    public struct ModifierFlags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let shift   = ModifierFlags(rawValue: 1 << 0)
        public static let control = ModifierFlags(rawValue: 1 << 1)
        public static let option  = ModifierFlags(rawValue: 1 << 2)
        public static let command = ModifierFlags(rawValue: 1 << 3)
    }

    /// Evdev keycodes used by the default table. Bare-name PascalCase per
    /// project convention (no `kVK_` prefix; that's a Carbon shape we
    /// shouldn't replicate verbatim).
    public enum KeyCode: UInt32, Hashable, Sendable {
        case escape    = 1
        case backspace = 14
        // Number row (evdev KEY_1=2 … KEY_9=10) — workspace switch/move binds.
        case one = 2, two = 3, three = 4, four = 5, five = 6
        case six = 7, seven = 8, eight = 9, nine = 10
        case q = 16, e = 18
        case b = 48, c = 46, m = 50
        case t = 20, p = 25, s = 31, f = 33
        case k = 37, l = 38, v = 47
        case slash = 53, space = 57
        // Tiling: arrow keys for half-tiles, u/i/j/k for the four corners (a
        // positional 2×2 cluster), Return to maximize. These are evdev
        // (physical) codes, like every bind here.
        case u = 22, i = 23, j = 36
        case enter = 28
        case leftBracket = 26, rightBracket = 27
        case up = 103, left = 105, right = 106, down = 108
    }

    public enum Phase: Sendable {
        case down
        case up
    }

    public struct Shortcut: Hashable, Sendable {
        public let key: KeyCode
        public let modifiers: ModifierFlags
        public init(key: KeyCode, modifiers: ModifierFlags) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    /// What a shortcut does. Swift-resolvable cases run inline during
    /// `dispatch` and return `.consume`. Cases that need reactor-side state
    /// (focused window, frame request, render invalidation) come back to
    /// the caller as `.deferred(action)`.
    public enum Action: Sendable {
        case launchApp(ids: [String], fallback: [String])
        /// Fire-and-forget a Noctalia IPC command (`noctalia msg <args>`). The
        /// compositor owns global hotkeys, so it binds the keys and drives
        /// Noctalia's panels/actions over IPC; Noctalia is a layer-shell client
        /// and cannot grab keys itself.
        case noctaliaMessage([String])

        // Deferred — executed reactor-side.
        case closeFocusedWindow
        case showWindowMenu
        case toggleHotkeyOverlay
        case dismissHotkeyOverlay
        case tile(TileDirection)
        case adjustBackdropIntensity(Float)
        /// Switch the focused output to the 1-based workspace index (created on
        /// demand). The executor resolves the output and runs the switch.
        case activateWorkspace(UInt32)
        /// Move the focused window to the 1-based workspace index on its output.
        case moveWindowToWorkspace(UInt32)
    }

    /// Mirrors `NucleusCompositorWindowManager.TileCommand`.
    /// Crossed as the deferred action's `value`; the executor drives the
    /// focused window's Swift role with it.
    public enum TileDirection: UInt32, Sendable {
        case left        = 1
        case right       = 2
        case top         = 3
        case bottom      = 4
        case topLeft     = 5
        case topRight    = 6
        case bottomLeft  = 7
        case bottomRight = 8
        case maximize    = 9
    }

    private enum KeybindKind: UInt8 {
        case pass = 0
        case consume = 1
        case deferred = 2
    }

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
        case action(Action)
    }

    public struct DeferredAction: Sendable {
        public let kind: UInt8
        public let value: UInt32
    }

    private var bindings: [Shortcut: Action]
    private var globallyCapturedKeys: Set<KeyCode> = []

    private init() {
        bindings = [
            // App launchers
            .init(key: .t, modifiers: .command):
                .launchApp(ids: ["kitty.desktop", "org.wezfurlong.wezterm.desktop", "foot.desktop"],
                           fallback: ["kitty"]),
            .init(key: .f, modifiers: .command):
                .launchApp(ids: ["foot.desktop", "kitty.desktop"],
                           fallback: ["foot"]),
            .init(key: .s, modifiers: .command):
                .launchApp(ids: ["sublime_text.desktop", "com.sublimetext.three.desktop", "code.desktop"],
                           fallback: ["subl"]),
            .init(key: .c, modifiers: .command):
                .launchApp(ids: ["google-chrome.desktop", "chromium.desktop"],
                           fallback: ["google-chrome"]),
            // Noctalia shell panels. The compositor must bind these (Noctalia
            // can't grab global keys) and drive them over `noctalia msg`. Keys
            // are placeholders — re-bind freely.
            .init(key: .space, modifiers: .command):
                .noctaliaMessage(["panel-toggle", "launcher"]),
            .init(key: .b, modifiers: .command):
                .noctaliaMessage(["panel-toggle", "control-center"]),

            // Session actions
            .init(key: .q, modifiers: .command): .closeFocusedWindow,
            .init(key: .m, modifiers: [.command, .shift]): .showWindowMenu,
            // Screenshots are owned by the shell (Noctalia) via wlr-screencopy; the
            // compositor no longer binds a screenshot key.
            .init(key: .slash, modifiers: .command): .toggleHotkeyOverlay,
            .init(key: .escape, modifiers: []): .dismissHotkeyOverlay,

            // Backdrop intensity is Swift state. The reactor receives only the frame
            // invalidation after this direct mutation, never the setting.
            .init(key: .leftBracket, modifiers: [.command, .option]): .adjustBackdropIntensity(-0.2),
            .init(key: .rightBracket, modifiers: [.command, .option]): .adjustBackdropIntensity(0.2),

            // Window tiling (Ctrl+Alt). Arrows half-tile; u/i/j/k corner-tile;
            // Return maximizes. Only Swift-role (xdg) windows tile; the
            // executor no-ops for xwayland/layer-shell.
            .init(key: .left, modifiers: [.control, .option]): .tile(.left),
            .init(key: .right, modifiers: [.control, .option]): .tile(.right),
            .init(key: .up, modifiers: [.control, .option]): .tile(.top),
            .init(key: .down, modifiers: [.control, .option]): .tile(.bottom),
            .init(key: .u, modifiers: [.control, .option]): .tile(.topLeft),
            .init(key: .i, modifiers: [.control, .option]): .tile(.topRight),
            .init(key: .j, modifiers: [.control, .option]): .tile(.bottomLeft),
            .init(key: .k, modifiers: [.control, .option]): .tile(.bottomRight),
            .init(key: .enter, modifiers: [.control, .option]): .tile(.maximize),
        ]

        // Workspaces (per-output, niri-like). Super+N switches to the N-th
        // workspace on the focused output (created on demand); Super+Shift+N moves
        // the focused window there. Registered programmatically so the 1..9 table
        // stays a single source of truth.
        let workspaceKeys: [KeyCode] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
        for (offset, key) in workspaceKeys.enumerated() {
            let index = UInt32(offset + 1)
            bindings[.init(key: key, modifiers: .command)] = .activateWorkspace(index)
            bindings[.init(key: key, modifiers: [.command, .shift])] = .moveWindowToWorkspace(index)
        }
    }

    public func register(_ shortcut: Shortcut, action: Action) {
        bindings[shortcut] = action
    }

    public func unregister(_ shortcut: Shortcut) {
        bindings.removeValue(forKey: shortcut)
    }

    public func dispatch(keycode: UInt32, modifiers: ModifierFlags, phase: Phase) -> Dispatch {
        switch resolve(keycode: keycode, modifiers: modifiers, phase: phase) {
        case .pass:
            return .pass
        case .consume:
            return .consume
        case .action(let action):
            return run(action)
        }
    }

    func resolve(keycode: UInt32, modifiers: ModifierFlags, phase: Phase) -> Resolution {
        if Self.isModifierKey(keycode) {
            return .pass
        }

        guard let key = KeyCode(rawValue: keycode) else {
            return .pass
        }

        guard phase == .down else {
            if globallyCapturedKeys.remove(key) != nil {
                return .consume
            }
            return .pass
        }

        let shortcut = Shortcut(key: key, modifiers: modifiers)
        if let action = bindings[shortcut] {
            globallyCapturedKeys.insert(key)
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

    private func run(_ action: Action) -> Dispatch {
        switch action {
        case .launchApp(let ids, let fallback):
            _ = LauncherService.shared.launchPreferred(ids: ids, fallback: fallback)
            return .consume

        case .noctaliaMessage(let args):
            _ = LauncherService.shared.spawn(["noctalia", "msg"] + args)
            return .consume

        case .closeFocusedWindow:
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
                kind: KeybindAction.tile.rawValue, value: direction.rawValue))
        case .adjustBackdropIntensity(let delta):
            let dynamics = WindowManager.shared.backdropResolver.dynamics
            let next = dynamics.target.resolvedIntensity + delta
            _ = WindowManager.shared.backdropResolver.dynamics.setIntensity(next)
            return .deferred(DeferredAction(
                kind: KeybindAction.backdropChanged.rawValue, value: 0))
        case .activateWorkspace(let index):
            return .deferred(DeferredAction(
                kind: KeybindAction.activateWorkspace.rawValue, value: index))
        case .moveWindowToWorkspace(let index):
            return .deferred(DeferredAction(
                kind: KeybindAction.moveWindowToWorkspace.rawValue, value: index))
        }
    }
}

extension KeybindService {
    /// Host entry called from `ShellPolicyHost.keybindDispatch`. Decomposes the
    /// raw modifier bits (the reactor's `EventFlags.raw()`), normalises to
    /// `ModifierFlags`, runs `dispatch`, and packs the result into the
    /// C decision struct.
    @inline(__always)
    static func bridgeDispatch(
        keycode: UInt32,
        modifierBits: UInt64,
        pressed: Bool
    ) -> NucleusCompositorOverlayTypes.KeybindDecision {
        let modifiers = decode(modifierBits: modifierBits)
        let phase: Phase = pressed ? .down : .up
        let decision = shared.dispatch(keycode: keycode, modifiers: modifiers, phase: phase)

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
                action: NucleusCompositorOverlayTypes.KeybindAction(rawValue: action.kind) ?? .none, reserved: 0, value: action.value)
        }
    }

    /// The reactor's `EventFlags` is a packed u64 mirroring `CGEventFlags`:
    /// shift=bit17, control=bit18, alternate=bit19, command=bit20. Decode
    /// to the Swift `ModifierFlags` option set.
    private static func decode(modifierBits: UInt64) -> ModifierFlags {
        var flags: ModifierFlags = []
        if (modifierBits & (1 << 17)) != 0 { flags.insert(.shift) }
        if (modifierBits & (1 << 18)) != 0 { flags.insert(.control) }
        if (modifierBits & (1 << 19)) != 0 { flags.insert(.option) }
        if (modifierBits & (1 << 20)) != 0 { flags.insert(.command) }
        return flags
    }
}
