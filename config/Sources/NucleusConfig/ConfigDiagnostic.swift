public import NucleusConfigSyntax

/// One problem found while loading configuration, in a form suitable for both a
/// terminal and the on-screen notice the compositor raises when a reload fails.
public struct ConfigDiagnostic: Equatable, Sendable {
    public enum Severity: Sendable, Equatable {
        /// The configuration cannot be used. The caller keeps what it has.
        case error
        /// The configuration is usable; something in it was ignored.
        case warning
    }

    public var severity: Severity
    public var message: String
    /// Where in the file, when the defect is positional.
    public var location: SourceLocation?
    /// Which setting, when the defect is semantic. `["input", "touchpad", "tap"]`.
    public var keyPath: [String]
    /// The offending source line with a caret under the column.
    public var excerpt: String?

    public init(
        severity: Severity,
        message: String,
        location: SourceLocation? = nil,
        keyPath: [String] = [],
        excerpt: String? = nil
    ) {
        self.severity = severity
        self.message = message
        self.location = location
        self.keyPath = keyPath
        self.excerpt = excerpt
    }

    /// A single-line summary: `12:5: error: unclosed '{'` or
    /// `error: input.touchpad.accel_speed: expected a number`.
    public var summary: String {
        var parts: [String] = []
        if let location { parts.append("\(location):") }
        parts.append(severity == .error ? "error:" : "warning:")
        if !keyPath.isEmpty { parts.append(keyPath.joined(separator: ".") + ":") }
        parts.append(message)
        return parts.joined(separator: " ")
    }

    /// The summary plus a source excerpt, when one is available.
    public var display: String {
        guard let excerpt else { return summary }
        return summary + "\n" + excerpt
    }
}

extension ConfigDiagnostic {
    /// Render the offending line with a caret beneath the column.
    ///
    /// The caret is placed by byte column, which is why `SourceLocation`
    /// documents its column that way — for the ASCII that JSON structure is
    /// made of, byte and display column agree.
    static func excerpt(
        for location: SourceLocation, in source: ConfigSource
    ) -> String {
        let text = source.line(location.line)
        guard !text.isEmpty else { return "" }
        let gutter = "\(location.line) | "
        let padding = String(
            repeating: " ", count: gutter.count + location.column - 1)
        return gutter + text + "\n" + padding + "^"
    }

    /// Build a diagnostic from a structural defect.
    static func from(
        _ error: ConfigSyntaxError, in source: ConfigSource
    ) -> ConfigDiagnostic {
        let location = error.primaryLocation
        return ConfigDiagnostic(
            severity: .error,
            message: error.message,
            location: location,
            excerpt: excerpt(for: location, in: source))
    }
}
