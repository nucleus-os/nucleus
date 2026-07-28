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

    /// Where a resolved configuration goes.
    ///
    /// One seam per section, applied only when that section changed. Editing a
    /// keybind should not reset every connected input device, and a touchpad
    /// tweak should not rebuild the bind table and drop its captured keys.
    /// Closures rather than runtime references so the reload decision is
    /// testable without bringing up a compositor.
    struct ApplySeams {
        var input: @MainActor (InputConfig) -> Void
        var binds: @MainActor ([KeyBind]) -> Void
        var outputs: @MainActor ([OutputConfig]) -> Void

        init(
            input: @escaping @MainActor (InputConfig) -> Void = { _ in },
            binds: @escaping @MainActor ([KeyBind]) -> Void = { _ in },
            outputs: @escaping @MainActor ([OutputConfig]) -> Void = { _ in }
        ) {
            self.input = input
            self.binds = binds
            self.outputs = outputs
        }
    }

    private let path: String
    private let watcher: LinuxFileWatcher?
    private let apply: ApplySeams
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
        apply: ApplySeams
    ) {
        guard let path else { return nil }
        self.path = path
        self.current = initial
        self.apply = apply
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

    /// Re-read the file immediately, as a control request asks.
    ///
    /// Shares the watcher's path so an explicit reload and a save behave
    /// identically — including keeping the running configuration when the file
    /// is bad.
    func reloadNow() -> Outcome {
        let outcome = apply(ConfigFile.load(path: path))
        onOutcome?(outcome)
        return outcome
    }

    /// Adopt a load result. Separated from the watcher so the decision of what
    /// a given outcome does to live state is testable on its own.
    func apply(_ result: ConfigLoadOutcome) -> Outcome {
        switch result {
        case .failed(let diagnostics):
            return Outcome(applied: false, diagnostics: diagnostics)
        case .loaded(let resolved, let warnings):
            // A save that changed nothing semantically — reformatting, an
            // edited comment — should disturb nothing.
            let inputChanged = resolved.input != current.input
            let bindsChanged = resolved.binds != current.binds
            let outputsChanged = resolved.outputs != current.outputs
            guard inputChanged || bindsChanged || outputsChanged else {
                return Outcome(applied: false, diagnostics: warnings)
            }
            current = resolved
            if inputChanged { apply.input(resolved.input) }
            if bindsChanged { apply.binds(resolved.binds) }
            // Re-attaching outputs is the most disruptive of the three, so it
            // is the one that most needs to happen only when it changed.
            if outputsChanged { apply.outputs(resolved.outputs) }
            return Outcome(applied: true, diagnostics: warnings)
        }
    }
}
