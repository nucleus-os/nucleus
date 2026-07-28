public struct ShellPreferences: Codable, Equatable, Sendable {
    public var cursorTheme: String
    public var idleTimeoutSeconds: UInt32

    public init(
        cursorTheme: String,
        idleTimeoutSeconds: UInt32
    ) {
        self.cursorTheme = cursorTheme
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }

    public static let defaults = ShellPreferences(
        cursorTheme: "default",
        idleTimeoutSeconds: 300)

    public func applying(
        _ part: ShellPreferencesPart
    ) -> ShellPreferences {
        ShellPreferences(
            cursorTheme: part.cursorTheme ?? cursorTheme,
            idleTimeoutSeconds:
                part.idleTimeoutSeconds ?? idleTimeoutSeconds)
    }
}

public struct ShellPreferencesPart:
    Decodable, Equatable, Sendable
{
    public var cursorTheme: String?
    public var idleTimeoutSeconds: UInt32?

    public init(
        cursorTheme: String? = nil,
        idleTimeoutSeconds: UInt32? = nil
    ) {
        self.cursorTheme = cursorTheme
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }
}
