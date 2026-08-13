package import NucleusCompositorServer
package import NucleusCompositorWindowManager
package import NucleusConfig
package import NucleusSessionProtocol

/// Complete server-policy graph. It contains no shell UI or shell service.
@MainActor
package final class CompositorPolicyServices {
    package let cursorTheme: ServerCursorThemeService
    package let bindings: GlobalBindingResolver
    package let policy: CompositorPolicyService

    package init(
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
        let gestures = CompositorGesturePolicy(server: server)
        policy = CompositorPolicyService(
            bindings: bindings,
            cursorTheme: cursorTheme,
            gestures: gestures,
            configurationEpoch: configurationEpoch,
            configurationGeneration: configurationGeneration)
    }

    package func adoptConfiguration(
        binds: [KeyBind],
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) {
        policy.adoptConfiguration(
            binds: binds,
            epoch: epoch,
            generation: generation)
    }

    package func adoptConfigurationVersion(
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) {
        policy.adoptConfigurationVersion(
            epoch: epoch,
            generation: generation)
    }
}
