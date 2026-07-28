// The framework owns the complete render-server process lifecycle. The runtime remains
// main-actor isolated, but its reactor wait suspends that actor so unrelated
// UI, process, and service tasks can make progress between host events.
import NucleusConfig
public import NucleusSessionProtocol

@MainActor
public func runNucleusCompositor(
    configuration: SessionConfiguration = .defaults,
    liveConfiguration: RenderServerConfiguration =
        NucleusConfiguration.defaults.renderServerProjection,
    configurationEpoch: ConfigurationServiceEpoch =
        ConfigurationServiceEpoch(high: 0, low: 0),
    configurationGeneration: ConfigurationGeneration =
        ConfigurationGeneration(rawValue: 0),
    configurationChannel: ConfigurationClientChannel? = nil,
    controlChannel: RenderServerControlChannel,
    shellPolicyAttachments:
        ShellPolicyAttachmentChannel? = nil,
    readinessReporter: SessionReadinessReporter? = nil
) async -> Int32 {
    // Session-runtime isolation first: validate the launcher-provided runtime dir
    // or create + export the direct-run fallback, so XDG_RUNTIME_DIR is set before
    // the router adds its listen socket. Torn down after the loop returns.
    let session: SessionIsolation
    do {
        session = try SessionIsolation.start(.fromEnvironment())
    } catch {
        logRuntime("session isolation failed: \(error)")
        return Int32(1)
    }
    defer { session.shutdown() }

    guard let runtime = CompositorRuntime(
        configuration: configuration,
        liveConfiguration: liveConfiguration,
        configurationEpoch: configurationEpoch,
        configurationGeneration: configurationGeneration,
        configurationChannel: configurationChannel,
        controlChannel: controlChannel,
        shellPolicyAttachments: shellPolicyAttachments,
        readinessReporter: readinessReporter)
    else { return Int32(1) }
    guard runtime.bringUp() else {
        await runtime.teardown()
        return Int32(1)
    }
    await runtime.run()
    await runtime.teardown()
    return Int32(0)
}
