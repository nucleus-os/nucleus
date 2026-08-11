import AndroidRuntimeColliderRecipe
import ColliderCore
import ColliderWorkspaceCommands
import ShellColliderRecipe
import SystemPackage

extension ComponentRegistry {
    func buildTracyReceivers(
        controls: TaskControls = TaskControls()
    ) async throws {
        let catalog = try componentCatalog()
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .bootstrap,
                    selection: "tracy")
            ],
            controls: controls)
    }

    func packageAndroidAddon(
        runtimeRoot: FilePath?,
        aospGeneration: FilePath,
        usesManagedAOSPGeneration: Bool,
        compatibility: FilePath,
        aospSigningKey: FilePath,
        addonSigningKey: FilePath,
        output: FilePath,
        controls: TaskControls = TaskControls()
    ) async throws {
        let configuration = AndroidAddonPackageConfiguration(
            swiftPM: try context.swiftPMInvocation(configuration: .release),
            runtimeRoot: runtimeRoot,
            runtimeScratch: context.layout.work.appending(
                "android-addon-runtime"),
            aospGeneration: aospGeneration,
            usesManagedAOSPGeneration: usesManagedAOSPGeneration,
            compatibility: compatibility,
            aospSigningKey: aospSigningKey,
            addonSigningKey: addonSigningKey,
            output: output,
            appArmorPolicy: context.layout.androidRuntime.appending(
                "container/lxc-nucleus-android.apparmor"),
            seccompPolicy: context.layout.androidRuntime.appending(
                "container/nucleus-android.seccomp"),
            environment: context.taskEnvironment)
        let shellConfiguration = try shellRuntimePublicationConfiguration(
            prefix: context.layout.developmentRuntimeCurrent,
            selection: RuntimeBuildSelection())
        let catalog = try componentCatalog(
            hostAugmentation: .linux(
                shellConfiguration: shellConfiguration,
                androidAddonConfiguration: configuration))
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: AndroidRuntimeEntrypoints.packageAddon,
                    selection: AndroidRuntimeColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }

    func publishDevelopmentRuntime(
        prefix: FilePath,
        selection: RuntimeBuildSelection,
        controls: TaskControls = TaskControls()
    ) async throws {
        let configuration = try shellRuntimePublicationConfiguration(
            prefix: prefix,
            selection: selection)
        let catalog = try componentCatalog(
            hostAugmentation: .linux(shellConfiguration: configuration))
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: .install,
                    selection: ShellColliderRecipe.descriptor.canonicalName)
            ],
            controls: controls)
    }
}
