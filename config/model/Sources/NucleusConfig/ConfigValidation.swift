/// Range checks that decoding cannot express.
///
/// `Codable` proves a value is a number; it cannot prove the number is one
/// libinput will accept. A setting that is silently clamped is a setting the
/// user believes they changed, so out-of-range values are reported rather than
/// quietly corrected — the clamp still happens, but it is not a secret.
extension NucleusConfiguration {
    public func validate() -> [ConfigValidationIssue] {
        var issues: [ConfigValidationIssue] = []
        input.validate(into: &issues)
        shell.validate(into: &issues)
        return issues
    }
}

extension ShellPreferences {
    func validate(into issues: inout [ConfigValidationIssue]) {
        if cursorTheme.isEmpty || cursorTheme.utf8.count > 4 * 1024 {
            issues.append(ConfigValidationIssue(
                severity: .error,
                message:
                    "must be a non-empty UTF-8 name no longer than 4096 bytes",
                keyPath: ["shell", "cursor_theme"]))
        }
        if idleTimeoutSeconds == 0
            || idleTimeoutSeconds > UInt32.max / 1000
        {
            issues.append(ConfigValidationIssue(
                severity: .error,
                message:
                    "must be between 1 and \(UInt32.max / 1000) seconds",
                keyPath: ["shell", "idle_timeout_seconds"]))
        }
    }
}

public struct ConfigValidationIssue: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case error
        case warning
    }

    public var severity: Severity
    public var message: String
    public var keyPath: [String]

    public init(
        severity: Severity,
        message: String,
        keyPath: [String]
    ) {
        self.severity = severity
        self.message = message
        self.keyPath = keyPath
    }
}

extension InputConfig {
    func validate(into issues: inout [ConfigValidationIssue]) {
        accelSpeedRange(
            touchpad.accelSpeed, at: ["input", "touchpad"], into: &issues)
        accelSpeedRange(
            mouse.accelSpeed, at: ["input", "mouse"], into: &issues)
        accelSpeedRange(
            trackpoint.accelSpeed, at: ["input", "trackpoint"], into: &issues)
        accelSpeedRange(
            trackball.accelSpeed, at: ["input", "trackball"], into: &issues)

        if keyboard.repeatRate > 1000 {
            issues.append(ConfigValidationIssue(
                severity: .warning,
                message: "must be 1000 or less; clamped",
                keyPath: ["input", "keyboard", "repeat_rate"]))
        }
    }

    private func accelSpeedRange(
        _ value: Double,
        at path: [String],
        into issues: inout [ConfigValidationIssue]
    ) {
        guard value < -1 || value > 1 else { return }
        issues.append(ConfigValidationIssue(
            severity: .warning,
            message: "must be between -1 and 1; clamped",
            keyPath: path + ["accel_speed"]))
    }
}
