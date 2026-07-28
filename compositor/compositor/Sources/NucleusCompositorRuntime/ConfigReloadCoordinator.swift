// ConfigReloadCoordinator — watches the session configuration file and adopts
// changes without a restart.
//
// The reload rule is that a bad file costs the *change*, never the session.
// Configuration gates everything a user can reach, so a reload that could fail
// the compositor would leave no way to fix the file that broke it. On failure
// the previously applied configuration stays in force and the diagnostic is
// reported; on success the new one is applied to hardware already connected.

public import NucleusConfig
import NucleusLinuxReactor

@MainActor
final class ConfigReloadCoordinator {
    /// What a reload attempt produced, for the owner to surface.
    struct Outcome {
        var applied: Bool
        var diagnostics: [ConfigDiagnostic]
    }

    private let path: String
    private let watcher: LinuxFileWatcher?
    /// Where a resolved configuration goes. A closure rather than a runtime
    /// reference so the reload decision — what a given load result does to
    /// live state — is testable without bringing up a compositor.
    private let applyInput: @MainActor (InputConfig) -> Void
    /// The configuration currently in force. Only replaced by a reload that
    /// resolved cleanly, so a failed attempt leaves it untouched.
    private(set) var current: NucleusConfiguration
    /// Called on every attempt, including ones that changed nothing.
    var onOutcome: (@MainActor (Outcome) -> Void)?

    /// Whether the file is being watched. False when the configuration
    /// directory does not exist, in which case bring-up values stay in force.
    var isWatching: Bool { watcher != nil }

    init?(
        initial: NucleusConfiguration,
        path: String? = ConfigFile.defaultPath(),
        applyInput: @escaping @MainActor (InputConfig) -> Void
    ) {
        guard let path else { return nil }
        self.path = path
        self.current = initial
        self.applyInput = applyInput
        self.watcher = LinuxFileWatcher(path: path)
        watcher?.onChange = { [weak self] change in
            self?.handle(change)
        }
    }

    var reactorSource: LinuxFileWatcher? { watcher }

    private func handle(_ change: LinuxFileWatcher.Change) {
        // A removed file means the user withdrew their configuration, which is
        // a request for defaults rather than a reason to keep enforcing values
        // no file supports any more.
        let outcome = change.removed
            ? apply(.loaded(.defaults, warnings: []))
            : apply(ConfigFile.load(path: path))
        onOutcome?(outcome)
    }

    /// Adopt a load result. Separated from the watcher so the decision of what
    /// a given outcome does to live state is testable on its own.
    func apply(_ result: ConfigLoadOutcome) -> Outcome {
        switch result {
        case .failed(let diagnostics):
            return Outcome(applied: false, diagnostics: diagnostics)
        case .loaded(let resolved, let warnings):
            guard resolved != current else {
                // A save that changed nothing semantically — reformatting, an
                // edited comment — should not disturb connected hardware.
                return Outcome(applied: false, diagnostics: warnings)
            }
            current = resolved
            applyInput(resolved.input)
            return Outcome(applied: true, diagnostics: warnings)
        }
    }
}
