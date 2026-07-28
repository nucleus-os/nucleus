/// The configuration consumed by the render-server process.
///
/// This is the complete policy surface that may affect privileged input,
/// window-management, output, and composition behavior. The server remains the
/// only raw global-key matcher.
public struct RenderServerConfiguration: Codable, Equatable, Sendable {
    public var input: InputConfig
    public var binds: [KeyBind]
    public var outputs: [OutputConfig]

    public init(
        input: InputConfig,
        binds: [KeyBind],
        outputs: [OutputConfig]
    ) {
        self.input = input
        self.binds = binds
        self.outputs = outputs
    }
}

/// The read-only configuration consumed by the shell process.
///
/// Binding entries are descriptive copies. The shell may display them and
/// execute actions accepted by the server, but it never matches raw keys.
public struct ShellConfiguration: Codable, Equatable, Sendable {
    public var displayedBinds: [KeyBind]
    public var cursorTheme: String
    public var idleTimeoutSeconds: UInt32

    public init(
        displayedBinds: [KeyBind],
        cursorTheme: String = ShellPreferences.defaults.cursorTheme,
        idleTimeoutSeconds: UInt32 =
            ShellPreferences.defaults.idleTimeoutSeconds
    ) {
        self.displayedBinds = displayedBinds
        self.cursorTheme = cursorTheme
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }
}

public extension NucleusConfiguration {
    var renderServerProjection: RenderServerConfiguration {
        RenderServerConfiguration(
            input: input,
            binds: binds,
            outputs: outputs)
    }

    var shellProjection: ShellConfiguration {
        ShellConfiguration(
            displayedBinds: binds,
            cursorTheme: shell.cursorTheme,
            idleTimeoutSeconds: shell.idleTimeoutSeconds)
    }
}
