import NucleusConfig
package import NucleusConfigSyntax

/// One problem found while loading configuration, in a form suitable for both a
/// terminal and the on-screen notice the compositor raises when a reload fails.
package struct ConfigDiagnostic: Equatable, Sendable {
    package enum Severity: Sendable, Equatable {
        /// The configuration cannot be used. The caller keeps what it has.
        case error
        /// The configuration is usable; something in it was ignored.
        case warning
    }

    package var severity: Severity
    package var message: String
    /// Where in the file, when the defect is positional.
    package var location: SourceLocation?
    /// Which setting, when the defect is semantic. `["input", "touchpad", "tap"]`.
    package var keyPath: [String]
    /// The offending source line with a caret under the column.
    package var excerpt: String?

    package init(
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

    package init(_ issue: ConfigValidationIssue) {
        self.init(
            severity: issue.severity == .error ? .error : .warning,
            message: issue.message,
            keyPath: issue.keyPath)
    }

    /// A single-line summary: `12:5: error: unclosed '{'` or
    /// `error: input.touchpad.accel_speed: expected a number`.
    package var summary: String {
        var parts: [String] = []
        if let location { parts.append("\(location):") }
        parts.append(severity == .error ? "error:" : "warning:")
        if !keyPath.isEmpty { parts.append(keyPath.joined(separator: ".") + ":") }
        parts.append(message)
        return parts.joined(separator: " ")
    }

    /// The summary plus a source excerpt, when one is available.
    package var display: String {
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
