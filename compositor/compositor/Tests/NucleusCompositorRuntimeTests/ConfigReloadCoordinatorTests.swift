import Foundation
import NucleusConfig
import Testing
@testable import NucleusCompositorRuntime

// What a reload does to live state. The governing rule is that a bad file costs
// the change, never the session: configuration gates everything a user can
// reach, so a reload able to fail the compositor would leave no way to repair
// the file that broke it.
@Suite @MainActor struct ConfigReloadCoordinatorTests {
    /// A coordinator over a real (empty) directory, recording what it applies.
    private final class Recorder {
        var applied: [InputConfig] = []
        var appliedBinds: [[KeyBind]] = []
        var appliedOutputs: [[OutputConfig]] = []
    }

    private func seams(_ recorder: Recorder) -> ConfigReloadCoordinator.ApplySeams {
        ConfigReloadCoordinator.ApplySeams(
            input: { recorder.applied.append($0) },
            binds: { recorder.appliedBinds.append($0) },
            outputs: { recorder.appliedOutputs.append($0) })
    }

    private func withCoordinator(
        initial: NucleusConfiguration = .defaults,
        _ body: @MainActor (ConfigReloadCoordinator, Recorder) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "nucleus-reload-tests-\(UInt64.random(in: 0..<UInt64.max))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        let built: ConfigReloadCoordinator? = ConfigReloadCoordinator(
            initial: initial,
            path: directory.appending(path: "config.json").path,
            apply: seams(recorder))
        let coordinator = try #require(built)
        try body(coordinator, recorder)
    }

    // MARK: successful reload

    @Test func aResolvedChangeIsAppliedAndBecomesCurrent() throws {
        try withCoordinator { coordinator, recorder in
            var changed = NucleusConfiguration.defaults
            changed.input.touchpad.tap = false
            let outcome = coordinator.apply(.loaded(changed, warnings: []))

            #expect(outcome.applied)
            #expect(outcome.diagnostics.isEmpty)
            #expect(coordinator.current == changed)
            #expect(recorder.applied.count == 1)
            #expect(recorder.applied.first?.touchpad.tap == false)
        }
    }

    @Test func warningsDoNotBlockAnOtherwiseUsableConfiguration() throws {
        try withCoordinator { coordinator, recorder in
            var changed = NucleusConfiguration.defaults
            changed.input.mouse.accelSpeed = 0.5
            let warning = ConfigDiagnostic(
                severity: .warning,
                message: "unknown setting; ignored",
                keyPath: ["input", "mouse", "typo"])
            let outcome = coordinator.apply(
                .loaded(changed, warnings: [warning]))

            // An ignored key must not cost a user their whole configuration.
            #expect(outcome.applied)
            #expect(outcome.diagnostics.count == 1)
            #expect(recorder.applied.count == 1)
        }
    }

    // MARK: failure

    @Test func aFailedLoadLeavesTheRunningConfigurationUntouched() throws {
        var initial = NucleusConfiguration.defaults
        initial.input.touchpad.accelSpeed = 0.25
        try withCoordinator(initial: initial) { coordinator, recorder in
            let error = ConfigDiagnostic(
                severity: .error, message: "unclosed '{'")
            let outcome = coordinator.apply(.failed([error]))

            #expect(!outcome.applied)
            #expect(outcome.diagnostics.count == 1)
            // Nothing reached the hardware, and what is in force is unchanged.
            #expect(recorder.applied.isEmpty)
            #expect(coordinator.current == initial)
        }
    }

    @Test func aFailureAfterASuccessKeepsTheLastGoodConfiguration() throws {
        try withCoordinator { coordinator, recorder in
            var good = NucleusConfiguration.defaults
            good.input.touchpad.tap = false
            #expect(coordinator.apply(.loaded(good, warnings: [])).applied)

            let outcome = coordinator.apply(.failed([ConfigDiagnostic(
                severity: .error, message: "unterminated string")]))
            #expect(!outcome.applied)
            #expect(coordinator.current == good)
            #expect(recorder.applied.count == 1)
        }
    }

    // MARK: no-op saves

    @Test func aSaveThatChangesNothingDoesNotDisturbConnectedHardware() throws {
        try withCoordinator { coordinator, recorder in
            // Reformatting or editing a comment reaches the watcher as a write
            // but resolves to the same values; re-applying would reset devices
            // for no reason.
            let outcome = coordinator.apply(
                .loaded(.defaults, warnings: []))
            #expect(!outcome.applied)
            #expect(recorder.applied.isEmpty)
        }
    }

    @Test func reapplyingTheSameChangeTwiceOnlyTouchesHardwareOnce() throws {
        try withCoordinator { coordinator, recorder in
            var changed = NucleusConfiguration.defaults
            changed.input.keyboard.repeatRate = 40
            #expect(coordinator.apply(.loaded(changed, warnings: [])).applied)
            #expect(!coordinator.apply(.loaded(changed, warnings: [])).applied)
            #expect(recorder.applied.count == 1)
        }
    }

    // MARK: per-section application

    @Test func aBindsOnlyChangeDoesNotTouchInputDevices() throws {
        try withCoordinator { coordinator, recorder in
            var changed = NucleusConfiguration.defaults
            changed.binds = [KeyBind(
                keys: KeyChord(modifiers: .superKey, keyCode: 16),
                action: .closeWindow)]
            #expect(coordinator.apply(.loaded(changed, warnings: [])).applied)

            // Rebinding a key has no business resetting a touchpad.
            #expect(recorder.applied.isEmpty)
            #expect(recorder.appliedBinds.count == 1)
        }
    }

    @Test func anInputOnlyChangeDoesNotRebuildTheBindTable() throws {
        try withCoordinator { coordinator, recorder in
            var changed = NucleusConfiguration.defaults
            changed.input.touchpad.accelSpeed = 0.4
            #expect(coordinator.apply(.loaded(changed, warnings: [])).applied)

            // Rebuilding the table would drop its captured keys, so a chord
            // held at that moment would never see its key-up.
            #expect(recorder.applied.count == 1)
            #expect(recorder.appliedBinds.isEmpty)
        }
    }

    @Test func aChangeToBothSectionsAppliesBoth() throws {
        try withCoordinator { coordinator, recorder in
            var changed = NucleusConfiguration.defaults
            changed.input.touchpad.tap = false
            changed.binds = []
            #expect(coordinator.apply(.loaded(changed, warnings: [])).applied)
            #expect(recorder.applied.count == 1)
            #expect(recorder.appliedBinds.count == 1)
            #expect(recorder.appliedBinds.first?.isEmpty == true)
        }
    }

    @Test func anOutputOnlyChangeTouchesNeitherInputNorBinds() throws {
        try withCoordinator { coordinator, recorder in
            var changed = NucleusConfiguration.defaults
            changed.outputs = [OutputConfig(name: "DP-1", scale: 1.5)]
            #expect(coordinator.apply(.loaded(changed, warnings: [])).applied)

            // Re-attaching outputs is disruptive; it must not be triggered by
            // an unrelated edit, nor trigger unrelated work itself.
            #expect(recorder.appliedOutputs.count == 1)
            #expect(recorder.appliedOutputs.first?.first?.scale == 1.5)
            #expect(recorder.applied.isEmpty)
            #expect(recorder.appliedBinds.isEmpty)
        }
    }

    @Test func anInputChangeDoesNotReattachOutputs() throws {
        try withCoordinator { coordinator, recorder in
            var changed = NucleusConfiguration.defaults
            changed.input.touchpad.tap = false
            #expect(coordinator.apply(.loaded(changed, warnings: [])).applied)
            #expect(recorder.appliedOutputs.isEmpty)
        }
    }

    // MARK: construction

    @Test func noResolvableLocationYieldsNoCoordinator() {
        #expect(ConfigReloadCoordinator(
            initial: .defaults, path: nil, apply: .init()) == nil)
    }

    @Test func aMissingDirectoryStillCoordinatesButDoesNotWatch() {
        // Bring-up values stay in force; there is simply nothing to observe
        // until the user creates a configuration directory.
        let coordinator = ConfigReloadCoordinator(
            initial: .defaults,
            path: "/nonexistent-nucleus-tree/nucleus/config.json",
            apply: .init())
        #expect(coordinator != nil)
        #expect(coordinator?.isWatching == false)
        #expect(coordinator?.reactorSource == nil)
    }

    @Test func anExistingDirectoryIsWatched() throws {
        try withCoordinator { coordinator, _ in
            #expect(coordinator.isWatching)
            #expect(coordinator.reactorSource != nil)
        }
    }

    // MARK: end to end

    /// Drive the real path: write the file, let the watcher observe it, and let
    /// the coordinator load and apply. Everything above tests the decision in
    /// isolation; this proves the loop is actually connected.
    private func withLiveReload(
        _ body: @MainActor (ConfigReloadCoordinator, Recorder, String) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "nucleus-live-reload-\(UInt64.random(in: 0..<UInt64.max))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "config.json").path
        let recorder = Recorder()
        let built: ConfigReloadCoordinator? = ConfigReloadCoordinator(
            initial: .defaults,
            path: path,
            apply: seams(recorder))
        let coordinator = try #require(built)
        try body(coordinator, recorder, path)
    }

    @Test func writingAValidFileReloadsItThroughTheWatcher() throws {
        try withLiveReload { coordinator, recorder, path in
            var outcomes: [ConfigReloadCoordinator.Outcome] = []
            coordinator.onOutcome = { outcomes.append($0) }

            try Data(#"{"input":{"touchpad":{"tap":false}}}"#.utf8)
                .write(to: URL(filePath: path))
            #expect(coordinator.reactorSource?.process() == true)

            #expect(recorder.applied.count == 1)
            #expect(recorder.applied.first?.touchpad.tap == false)
            #expect(coordinator.current.input.touchpad.tap == false)
            #expect(outcomes.first?.applied == true)
        }
    }

    @Test func writingAMalformedFileReportsWithoutApplying() throws {
        try withLiveReload { coordinator, recorder, path in
            var outcomes: [ConfigReloadCoordinator.Outcome] = []
            coordinator.onOutcome = { outcomes.append($0) }

            try Data("{\"input\": {\n".utf8).write(to: URL(filePath: path))
            #expect(coordinator.reactorSource?.process() == true)

            #expect(recorder.applied.isEmpty)
            let outcome = try #require(outcomes.first)
            #expect(!outcome.applied)
            #expect(outcome.diagnostics.contains { $0.severity == .error })
            // The diagnostic carries a position, which is what makes the
            // on-screen notice worth showing at all.
            #expect(outcome.diagnostics.first?.location != nil)
        }
    }

    @Test func repairingAFileAfterAFailureAppliesTheRepair() throws {
        try withLiveReload { coordinator, recorder, path in
            try Data("{\"input\": {\n".utf8).write(to: URL(filePath: path))
            _ = coordinator.reactorSource?.process()
            #expect(recorder.applied.isEmpty)

            try Data(#"{"input":{"mouse":{"natural_scroll":true}}}"#.utf8)
                .write(to: URL(filePath: path))
            _ = coordinator.reactorSource?.process()
            #expect(recorder.applied.count == 1)
            #expect(recorder.applied.first?.mouse.naturalScroll == true)
        }
    }

    @Test func deletingTheFileRevertsToDefaults() throws {
        try withLiveReload { coordinator, recorder, path in
            try Data(#"{"input":{"touchpad":{"tap":false}}}"#.utf8)
                .write(to: URL(filePath: path))
            _ = coordinator.reactorSource?.process()
            #expect(coordinator.current.input.touchpad.tap == false)

            // Withdrawing the configuration is a request for defaults, not a
            // reason to keep enforcing values no file supports any more.
            try FileManager.default.removeItem(at: URL(filePath: path))
            _ = coordinator.reactorSource?.process()
            #expect(coordinator.current == NucleusConfiguration.defaults)
            #expect(recorder.applied.last?.touchpad.tap == true)
        }
    }
}
