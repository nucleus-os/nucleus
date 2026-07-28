public import NucleusCompositorServer
public import NucleusCompositorWindowManager
public import NucleusConfig
public import NucleusSessionProtocol

/// Complete server-policy graph. It contains no shell UI or shell service.
@MainActor
public final class CompositorPolicyServices {
    public let cursorTheme: ServerCursorThemeService
    public let bindings: GlobalBindingResolver
    public let policy: CompositorPolicyService

    public init(
        server: NucleusCompositorServer,
        windowManager: WindowManager,
        binds: [KeyBind] = DefaultBinds.table,
        configurationEpoch: ConfigurationServiceEpoch =
            ConfigurationServiceEpoch(high: 0, low: 0),
        configurationGeneration: ConfigurationGeneration =
            ConfigurationGeneration(rawValue: 0)
    ) {
        cursorTheme = ServerCursorThemeService(server: server)
        bindings = GlobalBindingResolver(
            windowManager: windowManager,
            binds: binds)
        policy = CompositorPolicyService(
            bindings: bindings,
            cursorTheme: cursorTheme,
            configurationEpoch: configurationEpoch,
            configurationGeneration: configurationGeneration)
    }

    public func adoptConfiguration(
        binds: [KeyBind],
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) {
        policy.adoptConfiguration(
            binds: binds,
            epoch: epoch,
            generation: generation)
    }

    public func adoptConfigurationVersion(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) {
        policy.adoptConfigurationVersion(
            epoch: epoch,
            generation: generation)
    }
}
