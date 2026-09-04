import ChromiumColliderRecipe
import ColliderCore
import Foundation
import LinuxPackageAssembly
import LinuxPackageContracts
import SystemPackage

package struct PackageLinuxRuntimePayloadAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
        }
    }

    package static let kind: ActionKind = "linux.package-runtime-payload"

    private let execution: OCIExecution
    private let pipeline: OCIExecutionPipeline
    private let outputRoot: FilePath
    private let stageObservationReport: FilePath
    private let package: LinuxNativePackageName

    package var identity: Identity { Identity(execution: execution) }
    package var requirements: ActionRequirements { pipeline.requirements }

    package init(
        architecture: PlatformArchitecture,
        package: LinuxNativePackageName,
        runtimeArtifactRoot: FilePath,
        browser: ChromiumColliderRecipe.PackageInput,
        androidPackageInputRoot: FilePath? = nil,
        assemblerSwiftPM: SwiftPMInvocation,
        outputRoot: FilePath,
        placement: IdentityPathMap,
        environment: [String: String]
    ) throws {
        self.outputRoot = outputRoot
        self.package = package
        stageObservationReport = outputRoot.appending(".stage-observations.json")
        guard case .oci(let assemblerOCI) = assemblerSwiftPM.context.execution else {
            throw LinuxNativePackageExecutionFailure.requiresOCI
        }
        // Every path this execution names is the path the container sees.
        let containerPath = placement.executionPath
        let repositoryRoot = assemblerSwiftPM.context.packageRoot
            .removingLastComponent()
        var mounts = assemblerOCI.mounts.filter {
            $0.target != containerPath(repositoryRoot)
        }
        for mount in [
            OCIMount(
                source: assemblerSwiftPM.productsDirectory,
                target: containerPath(assemblerSwiftPM.productsDirectory),
                access: .readOnly),
            OCIMount(
                source: runtimeArtifactRoot,
                target: containerPath(runtimeArtifactRoot),
                access: .readOnly),
            OCIMount(
                source: browser.publication.distributionRoot,
                target: containerPath(browser.publication.distributionRoot),
                access: .readOnly),
            OCIMount(
                source: browser.publication.packageInputRoot,
                target: containerPath(browser.publication.packageInputRoot),
                access: .readOnly),
            OCIMount(boundedExport: outputRoot, target: containerPath(outputRoot)),
        ] {
            try appendMount(mount, to: &mounts)
        }
        if let androidPackageInputRoot {
            try appendMount(
                OCIMount(
                    source: androidPackageInputRoot,
                    target: containerPath(androidPackageInputRoot),
                    access: .readOnly),
                to: &mounts)
        }
        var containerEnvironment = assemblerOCI.containerEnvironment
        containerEnvironment["PATH"] =
            "/opt/swift/usr/bin:/usr/local/sbin:/usr/local/bin:"
            + "/usr/sbin:/usr/bin:/sbin:/bin"
        containerEnvironment["LD_LIBRARY_PATH"] = [
            assemblerOCI.containerEnvironment["LD_LIBRARY_PATH"],
            "/opt/swift/usr/lib/swift/linux",
        ].compactMap { $0 }.joined(separator: ":")
        let assembler = assemblerSwiftPM.executable("nucleus-linux-assembler")
        execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: architecture,
                abi: "glibc"),
            imageID: assemblerOCI.imageID,
            hostname: "nucleus-payload-\(architecture.rawValue)-\(package.rawValue)",
            workingDirectory: containerPath(outputRoot),
            hostWorkingDirectory: outputRoot,
            mounts: mounts,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: OCIResourceLimits(
                cpuCount: 2,
                memoryBytes: 8 * 1_024 * 1_024 * 1_024,
                processCount: 2_048),
            containerEnvironment: containerEnvironment,
            command: assemblerOCI.commandPrefix + [
                "fakeroot",
                containerPath(assembler),
                "payload",
                containerPath(runtimeArtifactRoot),
                containerPath(browser.publication.distributionRoot),
                containerPath(browser.publication.packageInputRoot),
                containerPath(outputRoot),
                architecture.rawValue,
                package.rawValue,
                androidPackageInputRoot.map(containerPath) ?? "-",
                containerPath(stageObservationReport),
            ],
            environment: environment,
            output: .logged)
        pipeline = try OCIExecutionPipeline([execution])
    }

    package func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(outputRoot)
        try context.files.remove(stageObservationReport)
        try await context.containers.run(execution)
        let observations = try JSONDecoder().decode(
            [ActionStageObservation].self,
            from: Data(context.files.read(stageObservationReport)))
        guard
            observations.map(\.name) == [
                LinuxNativePackageStage.payloadMaterialization.observationName,
                LinuxNativePackageChildStage.payloadMaterialization.observationName(
                    package: package),
            ]
        else {
            throw LinuxNativePackageExecutionFailure.invalidStageObservationReport
        }
        try context.files.remove(stageObservationReport)
        for observation in observations {
            context.observations.record(observation)
        }
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateLinuxNativePackagePayloadPublication(
            outputRoot,
            package: package,
            files: files)
    }
}
