import NucleusRenderServerRuntime
import NucleusConfig
public import NucleusSessionProtocol

/// Complete process bring-up state accepted by the private render-server
/// framework. Live policy arrives separately through the configuration
/// authority channel.
@_spi(NucleusRenderServer)
public struct RenderServerLaunchConfiguration {
    public var session: SessionConfiguration
    public var liveConfiguration: RenderServerConfiguration
    public var configurationEpoch: ConfigurationServiceEpoch
    public var configurationGeneration: ConfigurationGeneration
    public var configurationChannel: ConfigurationClientChannel?
    public var controlChannel: RenderServerControlChannel
    public var shellPolicyAttachments:
        ShellPolicyAttachmentChannel?
    public var readinessReporter: SessionReadinessReporter?

    public init(
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

@_spi(NucleusRenderServer)
public struct RenderServerTermination: Error, Sendable {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

/// The sole production entry point into the private render-server framework.
@_spi(NucleusRenderServer)
@MainActor
public func runRenderServer(
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
