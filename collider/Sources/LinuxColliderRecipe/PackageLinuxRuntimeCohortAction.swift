import ChromiumColliderRecipe
import ColliderCore
import Foundation
import LinuxPackageAssembly
import LinuxPackageContracts
import SystemPackage

package struct PackageLinuxRuntimeCohortAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
        }
    }

    package static let kind: ActionKind = "linux.package-runtime-cohort"

    private let execution: OCIExecution
    private let pipeline: OCIExecutionPipeline
    private let outputRoot: FilePath
    private let stageObservationReport: FilePath
    private let architecture: PlatformArchitecture

    package var identity: Identity { Identity(execution: execution) }
    package var requirements: ActionRequirements { pipeline.requirements }

    package init(
        architecture: PlatformArchitecture,
        sourceSnapshot: FilePath,
        runtimeArtifactRoot: FilePath,
        browser: ChromiumColliderRecipe.PackageInput,
        adapterRoot: FilePath,
        assemblerSwiftPM: SwiftPMInvocation,
        outputRoot: FilePath,
        producingTask: TaskID,
        producerRunner: RunnerPlatform,
        placement: IdentityPathMap,
        environment: [String: String]
    ) throws {
        self.outputRoot = outputRoot
        stageObservationReport = outputRoot.appending(
            ".package-stage-observations.json")
        self.architecture = architecture
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
        let sourceSnapshotRoot = sourceSnapshot.removingLastComponent()
        try appendMount(
            OCIMount(
                source: sourceSnapshotRoot,
                target: containerPath(sourceSnapshotRoot),
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: assemblerSwiftPM.productsDirectory,
                target: containerPath(assemblerSwiftPM.productsDirectory),
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: runtimeArtifactRoot,
                target: containerPath(runtimeArtifactRoot),
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: browser.publication.distributionRoot,
                target: containerPath(browser.publication.distributionRoot),
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: browser.publication.packageInputRoot,
                target: containerPath(browser.publication.packageInputRoot),
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: adapterRoot,
                target: containerPath(adapterRoot),
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: nativeBuilderIdentityMountRoot(assemblerOCI.imageID),
                target: containerPath(nativeBuilderIdentityMountRoot(assemblerOCI.imageID)),
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(boundedExport: outputRoot, target: containerPath(outputRoot)),
            to: &mounts)
        var containerEnvironment = assemblerOCI.containerEnvironment
        containerEnvironment["PATH"] =
            "/opt/swift/usr/bin:/usr/local/sbin:/usr/local/bin:"
            + "/usr/sbin:/usr/bin:/sbin:/bin"
        containerEnvironment["LD_LIBRARY_PATH"] = [
            assemblerOCI.containerEnvironment["LD_LIBRARY_PATH"],
            "/opt/swift/usr/lib/swift/linux",
        ].compactMap { $0 }.joined(separator: ":")
        let assembler = assemblerSwiftPM.executable(
            "nucleus-linux-assembler")
        execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: architecture,
                abi: "glibc"),
            imageID: assemblerOCI.imageID,
            hostname: "nucleus-package-\(architecture.rawValue)",
            workingDirectory: containerPath(outputRoot),
            hostWorkingDirectory: outputRoot,
            mounts: mounts,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .parallelBuild,
            containerEnvironment: containerEnvironment,
            command: assemblerOCI.commandPrefix + [
                "fakeroot",
                containerPath(assembler),
                "packages",
                containerPath(sourceSnapshot),
                containerPath(runtimeArtifactRoot),
                containerPath(browser.publication.distributionRoot),
                containerPath(browser.publication.packageInputRoot),
                containerPath(adapterRoot),
                containerPath(outputRoot),
                architecture.rawValue,
                containerPath(assembler),
                producerRunner.operatingSystem.rawValue,
                producerRunner.architecture.rawValue,
                containerPath(assemblerOCI.imageID),
                producingTask.rawValue,
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
        let names = observations.map(\.name)
        guard
            names.contains(
                LinuxNativePackageStage.productEnvelopeConstruction
                    .observationName),
            names.contains(
                LinuxNativePackageStage.generationPublication.observationName)
        else {
            throw LinuxNativePackageExecutionFailure.invalidStageObservationReport
        }
        try context.files.remove(stageObservationReport)
        for observation in observations {
            context.observations.record(observation)
        }
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateLinuxNativePackagePublication(
            architecture: architecture,
            outputRoot: outputRoot,
            files: files)
    }
}

package func nativeBuilderIdentityMountRoot(_ imageID: FilePath) -> FilePath {
    imageID.removingLastComponent()
}

package func appendMount(
    _ mount: OCIMount,
    to mounts: inout [OCIMount]
) throws {
    if let existing = mounts.first(where: { $0.target == mount.target }) {
        guard existing == mount else {
            throw LinuxNativePackageExecutionFailure.conflictingMount(mount.target)
        }
        return
    }
    mounts.append(mount)
}

package enum LinuxNativePackageExecutionFailure: Error,
    CustomStringConvertible, Sendable
{
    case requiresOCI
    case conflictingMount(String)
    case invalidStageObservationReport

    package var description: String {
        switch self {
        case .requiresOCI:
            "Linux native package assembly requires the Linux OCI builder"
        case .conflictingMount(let target):
            "Linux native package assembly has conflicting OCI mount '\(target)'"
        case .invalidStageObservationReport:
            "Linux native package assembly produced an incomplete stage observation report"
        }
    }
}
