@testable import NucleusConfig
import Testing

@Suite struct ShellPreferencesTests {
    @Test func projectionsAssignPreferenceAndMechanismOwnership() {
        var configuration = NucleusConfiguration.defaults
        configuration.shell = ShellPreferences(
            cursorTheme: "Bibata-Modern-Ice",
            idleTimeoutSeconds: 90)

        let shell = configuration.shellProjection
        #expect(shell.cursorTheme == "Bibata-Modern-Ice")
        #expect(shell.idleTimeoutSeconds == 90)
        #expect(configuration.renderServerProjection.input
            == configuration.input)
    }

    @Test func invalidCursorAndIdlePreferencesAreRejected() {
        var configuration = NucleusConfiguration.defaults
        configuration.shell = ShellPreferences(
            cursorTheme: "",
            idleTimeoutSeconds: 0)

        let issues = configuration.validate()

        #expect(issues.map(\.keyPath).contains(
            ["shell", "cursor_theme"]))
        #expect(issues.map(\.keyPath).contains(
            ["shell", "idle_timeout_seconds"]))
        #expect(issues.allSatisfy { $0.severity == .error })
    }

    @Test func partialShellPreferencesMergeOverDefaults() {
        var part = NucleusConfigurationPart()
        part.shell = ShellPreferencesPart(cursorTheme: "Adwaita")
        let resolved = NucleusConfiguration.defaults.applying(part)

        #expect(resolved.shell.cursorTheme == "Adwaita")
        #expect(resolved.shell.idleTimeoutSeconds
            == ShellPreferences.defaults.idleTimeoutSeconds)
    }
}
