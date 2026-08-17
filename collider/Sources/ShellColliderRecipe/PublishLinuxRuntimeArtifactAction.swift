import ColliderCore
import SystemPackage

package struct PublishLinuxRuntimeArtifactAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
        }
    }

    package static let kind: ActionKind = "linux.publish-runtime-artifact"

    private let execution: OCIExecution
    private let pipeline: OCIExecutionPipeline
    private let artifactRoot: FilePath

    package var identity: Identity { Identity(execution: execution) }
    package var requirements: ActionRequirements { pipeline.requirements }

    package init(
        runtimeSwiftPM: SwiftPMInvocation,
        assemblerSwiftPM: SwiftPMInvocation,
        architecture: PlatformArchitecture,
        artifactRoot: FilePath,
        generationsRoot: FilePath,
        packageManifestsRoot: FilePath,
        rollbackGenerationCount: UInt32,
        sessionPackage: FilePath,
        kernelContract: FilePath,
        environment: [String: String]
    ) throws {
        self.artifactRoot = artifactRoot
        guard case .oci(let runtimeOCI) = runtimeSwiftPM.context.execution,
            case .oci(let assemblerOCI) = assemblerSwiftPM.context.execution,
            runtimeOCI.imageID == assemblerOCI.imageID
        else {
            throw PublishLinuxRuntimeArtifactFailure.incompatibleBuildContexts
        }

        var mounts = runtimeOCI.mounts
        let runtimeProducts = OCIMount(
            source: runtimeSwiftPM.productsDirectory,
            target: runtimeSwiftPM.productsDirectory.string,
            access: .readOnly)
        guard !mounts.contains(where: { $0.target == runtimeProducts.target }) else {
            throw PublishLinuxRuntimeArtifactFailure.conflictingMount(
                runtimeProducts.target)
        }
        mounts.append(runtimeProducts)
        let assemblerProducts = OCIMount(
            source: assemblerSwiftPM.productsDirectory,
            target: assemblerSwiftPM.productsDirectory.string,
            access: .readOnly)
        guard !mounts.contains(where: { $0.target == assemblerProducts.target }) else {
            throw PublishLinuxRuntimeArtifactFailure.conflictingMount(
                assemblerProducts.target)
        }
        mounts.append(assemblerProducts)
        let artifactMount = OCIMount(
            boundedExport: artifactRoot,
            target: artifactRoot.string)
        guard !mounts.contains(where: { $0.target == artifactMount.target }) else {
            throw PublishLinuxRuntimeArtifactFailure.conflictingMount(
                artifactMount.target)
        }
        mounts.append(artifactMount)

        var containerEnvironment = runtimeOCI.containerEnvironment
        containerEnvironment["PATH"] =
            "/opt/swift/usr/bin:/usr/local/sbin:/usr/local/bin:"
            + "/usr/sbin:/usr/bin:/sbin:/bin"
        containerEnvironment["LD_LIBRARY_PATH"] =
            assemblerOCI.containerEnvironment["LD_LIBRARY_PATH"]

        execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: architecture,
                abi: "glibc"),
            imageID: runtimeOCI.imageID,
            hostname: "nucleus-runtime-artifact-\(architecture.rawValue)",
            workingDirectory: runtimeSwiftPM.context.packageRoot.string,
            hostWorkingDirectory: runtimeSwiftPM.context.packageRoot,
            mounts: mounts,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .build,
            containerEnvironment: containerEnvironment,
            command: assemblerOCI.commandPrefix + [
                assemblerSwiftPM.executable("nucleus-linux-runtime-publisher").string,
                runtimeSwiftPM.productsDirectory.string,
                artifactRoot.appending("current").string,
                generationsRoot.string,
                packageManifestsRoot.string,
                String(rollbackGenerationCount),
                sessionPackage.string,
                kernelContract.string,
                "release",
                architecture.rawValue,
            ],
            environment: environment,
            output: .logged)
        pipeline = try OCIExecutionPipeline([execution])
    }

    package func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(artifactRoot)
        try await context.containers.run(execution)
    }
}

package enum PublishLinuxRuntimeArtifactFailure: Error,
    CustomStringConvertible, Sendable
{
    case incompatibleBuildContexts
    case conflictingMount(String)

    package var description: String {
        switch self {
        case .incompatibleBuildContexts:
            "runtime products and the assembler must use one OCI builder image"
        case .conflictingMount(let target):
            "Linux runtime artifact assembly has conflicting OCI mount '\(target)'"
        }
    }
}
