/// Range checks that decoding cannot express.
///
/// `Codable` proves a value is a number; it cannot prove the number is one
/// libinput will accept. A setting that is silently clamped is a setting the
/// user believes they changed, so out-of-range values are reported rather than
/// quietly corrected — the clamp still happens, but it is not a secret.
extension NucleusConfiguration {
    public func validate() -> [ConfigDiagnostic] {
        var diagnostics: [ConfigDiagnostic] = []
        input.validate(into: &diagnostics)
        return diagnostics
    }
}

extension InputConfig {
    func validate(into diagnostics: inout [ConfigDiagnostic]) {
        accelSpeedRange(
            touchpad.accelSpeed, at: ["input", "touchpad"], into: &diagnostics)
        accelSpeedRange(
            mouse.accelSpeed, at: ["input", "mouse"], into: &diagnostics)
        accelSpeedRange(
            trackpoint.accelSpeed, at: ["input", "trackpoint"], into: &diagnostics)
        accelSpeedRange(
            trackball.accelSpeed, at: ["input", "trackball"], into: &diagnostics)

        if keyboard.repeatRate > 1000 {
            diagnostics.append(ConfigDiagnostic(
                severity: .warning,
                message: "must be 1000 or less; clamped",
                keyPath: ["input", "keyboard", "repeat_rate"]))
        }
    }

    private func accelSpeedRange(
        _ value: Double,
        at path: [String],
        into diagnostics: inout [ConfigDiagnostic]
    ) {
        guard value < -1 || value > 1 else { return }
        diagnostics.append(ConfigDiagnostic(
            severity: .warning,
            message: "must be between -1 and 1; clamped",
            keyPath: path + ["accel_speed"]))
    }
}
