import NucleusConfig
import NucleusSessionProtocol

package enum ShellFeedbackState: Sendable, Equatable {
    case hidden
    case hotkey
    case windowMenu(
        windowID: UInt64,
        x: Double,
        y: Double,
        capabilities: UInt32)
}

package enum ShellObservedIdleState: Sendable, Equatable {
    case active
    case idle
}

/// Executes only actions already accepted by the server.
///
/// It never receives raw keys and never performs chord matching. Publications
/// retain the server's configuration epoch/generation for diagnostics and
/// deterministic UI state.
@MainActor
package final class ShellActionDispatcher {
    package let launcher: LauncherService
    package private(set) var feedback: ShellFeedbackState = .hidden
    package private(set) var lastAcceptedEpoch: ConfigurationServiceEpoch?
    package private(set) var lastAcceptedGeneration: ConfigurationGeneration?
    package private(set) var idleState: ShellObservedIdleState = .active
    package var onFeedbackChanged: ((ShellFeedbackState) -> Void)?

    package init(launcher: LauncherService = LauncherService()) {
        self.launcher = launcher
    }

    @discardableResult
    package func receive(
        _ publication: ShellPolicyPublication
    ) -> Bool {
        switch publication.kind {
        case .ready:
            return false
        case .acceptedAction:
            guard let action = publication.action,
                let epoch = publication.configurationEpoch,
                let generation =
                    publication.configurationGeneration
            else { return false }
            lastAcceptedEpoch = epoch
            lastAcceptedGeneration = generation
            switch action {
            case .launch(let appIDs, let command):
                return launcher.launchPreferred(
                    ids: appIDs,
                    fallback: command)
            case .toggleHotkeyOverlay:
                setFeedback(feedback == .hotkey ? .hidden : .hotkey)
                return true
            case .dismissHotkeyOverlay:
                setFeedback(.hidden)
                return true
            case .showWindowMenu:
                return false
            case .closeWindow, .tile, .adjustBackdropIntensity,
                .activateWorkspace, .moveWindowToWorkspace:
                // These are server mechanism and must never cross this seam.
                return false
            }
        case .windowMenuOffered:
            guard let windowID = publication.windowID,
                let x = publication.x,
                let y = publication.y,
                let capabilities =
                    publication.windowCapabilities
            else { return false }
            lastAcceptedEpoch = publication.configurationEpoch
            lastAcceptedGeneration =
                publication.configurationGeneration
            setFeedback(
                .windowMenu(
                    windowID: windowID,
                    x: x,
                    y: y,
                    capabilities: capabilities))
            return true
        }
    }

    package func receiveIdleState(
        _ state: ShellObservedIdleState,
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) {
        idleState = state
        lastAcceptedEpoch = epoch
        lastAcceptedGeneration = generation
    }

    package func dismissFeedback() {
        setFeedback(.hidden)
    }

    private func setFeedback(_ next: ShellFeedbackState) {
        guard next != feedback else { return }
        feedback = next
        onFeedbackChanged?(next)
    }
}
