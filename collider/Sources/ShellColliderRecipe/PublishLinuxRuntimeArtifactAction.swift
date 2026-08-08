import ColliderCore
import SystemPackage

package struct PublishLinuxRuntimeArtifactAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(
                tag: 1,
                nested: OCIExecutionActionIdentity(execution))
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
        artifactRoot: FilePath,
        generationsRoot: FilePath,
        packageManifestsRoot: FilePath,
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
        let assemblerProducts = OCIMount(
            source: assemblerSwiftPM.scratchPath,
            target: assemblerSwiftPM.scratchPath.string,
            access: .readOnly)
        guard !mounts.contains(where: { $0.target == assemblerProducts.target }) else {
            throw PublishLinuxRuntimeArtifactFailure.conflictingMount(
                assemblerProducts.target)
        }
        mounts.append(assemblerProducts)
        let artifactMount = OCIMount(
            source: artifactRoot,
            target: artifactRoot.string,
            access: .readWrite)
        guard !mounts.contains(where: { $0.target == artifactMount.target }) else {
            throw PublishLinuxRuntimeArtifactFailure.conflictingMount(
                artifactMount.target)
        }
        mounts.append(artifactMount)

        var containerEnvironment = runtimeOCI.containerEnvironment
        containerEnvironment["PATH"] =
            "/opt/swift/usr/bin:/usr/local/sbin:/usr/local/bin:"
            + "/usr/sbin:/usr/bin:/sbin:/bin"
        let swiftRuntime = "/opt/swift/usr/lib/swift/linux"
        containerEnvironment["LD_LIBRARY_PATH"] = [
            runtimeOCI.containerEnvironment["LD_LIBRARY_PATH"],
            swiftRuntime,
        ].compactMap { $0 }.joined(separator: ":")

        execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: runtimeOCI.imageID,
            hostname: "nucleus-runtime-artifact",
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
                assemblerSwiftPM.executable("nucleus-runtime-assembler").string,
                runtimeSwiftPM.productsDirectory.string,
                artifactRoot.appending("current").string,
                generationsRoot.string,
                packageManifestsRoot.string,
                sessionPackage.string,
                kernelContract.string,
                "release",
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
