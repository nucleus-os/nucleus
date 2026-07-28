public import NucleusCompositorWindowManager
public import NucleusConfig

/// Compositor session-policy keybind table.
///
/// Apple-shape analog: loginwindow/SkyLight's global hotkey policy layered on
/// top of WindowServer event taps. The reactor's event tap forwards every
/// keyboard event to its runtime-owned `GlobalBindingResolver` and acts on the
/// returned `Dispatch`.
///
/// The table comes from configuration. Chords and actions are the shared
/// `NucleusConfig` vocabulary rather than types private to this service,
/// because the control socket has to name the same operations a binding names —
/// defining "close the focused window" twice would guarantee the two drift.
@MainActor
public final class GlobalBindingResolver {
    public enum Phase: Sendable {
        case down
        case up
    }

    /// Stable server-to-shell action vocabulary. Values are protocol ABI.
    public enum AcceptedAction: UInt8, Sendable {
        case none = 0
        case launch = 1
        case toggleHotkey = 2
        case dismissHotkey = 3
        case windowMenu = 4
        case closeFocused = 5
        case tile = 6
        case backdropChanged = 7
        case activateWorkspace = 8
        case moveWindowToWorkspace = 9
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
        public let kind: AcceptedAction
        /// Index into the exact configuration-generation binding projection.
        public let configurationIndex: UInt32
        public let value: UInt32
    }

    private struct Binding: Sendable {
        var configurationIndex: UInt32
        var action: BindAction
    }

    private var bindings: [KeyChord: Binding]
    private var globallyCapturedKeys: Set<UInt32> = []
    private unowned let windowManager: WindowManager

    public init(
        windowManager: WindowManager,
        binds: [KeyBind] = DefaultBinds.table
    ) {
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
    private static func table(from binds: [KeyBind]) -> [KeyChord: Binding] {
        var table: [KeyChord: Binding] = [:]
        for (index, bind) in binds.enumerated() {
            table[bind.keys] = Binding(
                configurationIndex: UInt32(index),
                action: bind.action)
        }
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
        if let binding = bindings[chord] {
            globallyCapturedKeys.insert(keycode)
            return .action(binding.action)
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
        run(action, configurationIndex: .max)
    }

    private func run(
        _ action: BindAction,
        configurationIndex: UInt32
    ) -> Dispatch {
        switch action {
        case .launch:
            return .deferred(DeferredAction(
                kind: .launch,
                configurationIndex: configurationIndex,
                value: 0))

        case .closeWindow:
            return .deferred(DeferredAction(
                kind: .closeFocused,
                configurationIndex: configurationIndex,
                value: 0))
        case .showWindowMenu:
            return .deferred(DeferredAction(
                kind: .windowMenu,
                configurationIndex: configurationIndex,
                value: 0))
        case .toggleHotkeyOverlay:
            return .deferred(DeferredAction(
                kind: .toggleHotkey,
                configurationIndex: configurationIndex,
                value: 0))
        case .dismissHotkeyOverlay:
            return .deferred(DeferredAction(
                kind: .dismissHotkey,
                configurationIndex: configurationIndex,
                value: 0))
        case .tile(let direction):
            return .deferred(DeferredAction(
                kind: .tile,
                configurationIndex: configurationIndex,
                value: Self.wireValue(direction)))
        case .adjustBackdropIntensity(let delta):
            let next = windowManager.backdropResolver.dynamics
                .target.resolvedIntensity + Float(delta)
            _ = windowManager.backdropResolver.dynamics.setIntensity(next)
            return .deferred(DeferredAction(
                kind: .backdropChanged,
                configurationIndex: configurationIndex,
                value: 0))
        case .activateWorkspace(let index):
            return .deferred(DeferredAction(
                kind: .activateWorkspace,
                configurationIndex: configurationIndex,
                value: index))
        case .moveWindowToWorkspace(let index):
            return .deferred(DeferredAction(
                kind: .moveWindowToWorkspace,
                configurationIndex: configurationIndex,
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

extension GlobalBindingResolver {
    public func bridgeDispatch(
        keycode: UInt32,
        modifierBits: UInt64,
        pressed: Bool
    ) -> Dispatch {
        let modifiers = Self.decode(modifierBits: modifierBits)
        let phase: Phase = pressed ? .down : .up
        switch resolve(
            keycode: keycode, modifiers: modifiers, phase: phase)
        {
        case .pass:
            return .pass
        case .consume:
            return .consume
        case .action(let action):
            let chord = KeyChord(
                modifiers: modifiers,
                keyCode: keycode)
            return run(
                action,
                configurationIndex:
                    bindings[chord]?.configurationIndex ?? .max)
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
