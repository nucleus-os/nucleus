import NucleusConfig
import NucleusSessionProtocol
@testable import NucleusShellServices
import Testing

@MainActor
@Suite struct ShellActionDispatcherTests {
    @Test func acceptedActionRetainsServerConfigurationIdentity() {
        let dispatcher = ShellActionDispatcher(
            launcher: LauncherService(
                applicationIndex: DesktopApplicationIndex()))
        let epoch = ConfigurationServiceEpoch(high: 7, low: 9)
        let generation = ConfigurationGeneration(rawValue: 11)

        #expect(dispatcher.receive(ShellPolicyPublication(
            kind: .acceptedAction,
            action: .toggleHotkeyOverlay,
            configurationIndex: 3,
            configurationEpoch: epoch,
            configurationGeneration: generation)))
        #expect(dispatcher.feedback == .hotkey)
        #expect(dispatcher.lastAcceptedEpoch == epoch)
        #expect(dispatcher.lastAcceptedGeneration == generation)
    }

    @Test func serverMechanismActionIsNeverExecutedByShell() {
        let dispatcher = ShellActionDispatcher(
            launcher: LauncherService(
                applicationIndex: DesktopApplicationIndex()))

        #expect(!dispatcher.receive(ShellPolicyPublication(
            kind: .acceptedAction,
            action: .closeWindow,
            configurationEpoch:
                ConfigurationServiceEpoch(high: 1, low: 2),
            configurationGeneration:
                ConfigurationGeneration(rawValue: 3))))
        #expect(dispatcher.feedback == .hidden)
    }

    @Test func standardIdleEventsUpdateObservedState() {
        let dispatcher = ShellActionDispatcher(
            launcher: LauncherService(
                applicationIndex: DesktopApplicationIndex()))
        let epoch = ConfigurationServiceEpoch(high: 4, low: 5)
        let generation = ConfigurationGeneration(rawValue: 6)

        dispatcher.receiveIdleState(
            .idle,
            epoch: epoch,
            generation: generation)

        #expect(dispatcher.idleState == .idle)
        #expect(dispatcher.lastAcceptedEpoch == epoch)
        #expect(dispatcher.lastAcceptedGeneration == generation)
    }
}
