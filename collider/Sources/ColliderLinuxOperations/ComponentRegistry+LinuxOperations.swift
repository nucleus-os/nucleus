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

    func materializeAndroidPackageInput(
        runtimeRoot: FilePath?,
        aospGeneration: FilePath,
        usesManagedAOSPGeneration: Bool,
        aospSigningKey: FilePath,
        output: FilePath,
        controls: TaskControls = TaskControls()
    ) async throws {
        let configuration = AndroidPackageInputConfiguration(
            swiftPM: try context.swiftPMInvocation(configuration: .release),
            // A Linux host materializes natively, so it packages for the
            // architecture it is. A containerized materialization is told
            // which architecture it packages for, because the builder image
            // is arm64 whatever the AOSP product holds.
            architecture: RunnerPlatform.current.architecture,
            runtimeRoot: runtimeRoot,
            runtimeScratch: context.workRoot.appending(
                "android-package-input-runtime"),
            aospGeneration: aospGeneration,
            usesManagedAOSPGeneration: usesManagedAOSPGeneration,
            aospSigningKey: aospSigningKey,
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
                androidPackageConfiguration: configuration))
        try await context.execute(
            catalog: catalog,
            requests: [
                ComponentEntrypointRequest(
                    entrypoint: AndroidRuntimeEntrypoints.packageInput,
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
