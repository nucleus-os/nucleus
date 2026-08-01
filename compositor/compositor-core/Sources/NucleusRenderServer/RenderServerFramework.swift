import NucleusConfig
import NucleusRenderServerRuntime
package import NucleusSessionProtocol

/// Complete process bring-up state accepted by the private render-server
/// framework. Live policy arrives separately through the configuration
/// authority channel.
package struct RenderServerLaunchConfiguration {
    package var session: SessionConfiguration
    package var liveConfiguration: RenderServerConfiguration
    package var configurationEpoch: ConfigurationServiceEpoch
    package var configurationGeneration: ConfigurationGeneration
    package var configurationChannel: ConfigurationClientChannel?
    package var controlChannel: RenderServerControlChannel
    package var shellPolicyAttachments: ShellPolicyAttachmentChannel?
    package var readinessReporter: SessionReadinessReporter?

    package init(
        session: SessionConfiguration,
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
        readinessReporter: SessionReadinessReporter?
    ) {
        self.session = session
        self.liveConfiguration = liveConfiguration
        self.configurationEpoch = configurationEpoch
        self.configurationGeneration = configurationGeneration
        self.configurationChannel = configurationChannel
        self.controlChannel = controlChannel
        self.shellPolicyAttachments = shellPolicyAttachments
        self.readinessReporter = readinessReporter
    }
}

package struct RenderServerTermination: Error, Sendable {
    package let status: Int32

    package init(status: Int32) {
        self.status = status
    }
}

/// The sole production entry point into the private render-server framework.
@MainActor
package func runRenderServer(
    configuration: RenderServerLaunchConfiguration
) async throws {
    let status = await runNucleusCompositor(
        configuration: configuration.session,
        liveConfiguration: configuration.liveConfiguration,
        configurationEpoch: configuration.configurationEpoch,
        configurationGeneration: configuration.configurationGeneration,
        configurationChannel: configuration.configurationChannel,
        controlChannel: configuration.controlChannel,
        shellPolicyAttachments:
            configuration.shellPolicyAttachments,
        readinessReporter: configuration.readinessReporter)
    guard status == 0 else {
        throw RenderServerTermination(status: status)
    }
}
