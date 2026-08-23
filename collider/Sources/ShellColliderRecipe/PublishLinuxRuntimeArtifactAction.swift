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
        targetLibraryRoots: [FilePath],
        artifactRoot: FilePath,
        generationsRoot: FilePath,
        packageManifestsRoot: FilePath,
        rollbackGenerationCount: UInt32,
        sessionPackage: FilePath,
        placement: IdentityPathMap,
        environment: [String: String]
    ) throws {
        self.artifactRoot = artifactRoot
        guard case .oci(let runtimeOCI) = runtimeSwiftPM.context.execution,
            case .oci(let assemblerOCI) = assemblerSwiftPM.context.execution,
            runtimeOCI.imageID == assemblerOCI.imageID
        else {
            throw PublishLinuxRuntimeArtifactFailure.incompatibleBuildContexts
        }

        // Every path this execution names is the path the container sees.
        // These inputs live under declared placement roots, so naming them by
        // their host locations would make one artifact's identity depend on
        // where this checkout and cache happen to sit.
        let containerPath = placement.executionPath
        var mounts = runtimeOCI.mounts
        let runtimeProducts = OCIMount(
            source: runtimeSwiftPM.productsDirectory,
            target: containerPath(runtimeSwiftPM.productsDirectory),
            access: .readOnly)
        guard !mounts.contains(where: { $0.target == runtimeProducts.target }) else {
            throw PublishLinuxRuntimeArtifactFailure.conflictingMount(
                runtimeProducts.target)
        }
        mounts.append(runtimeProducts)
        let assemblerProducts = OCIMount(
            source: assemblerSwiftPM.productsDirectory,
            target: containerPath(assemblerSwiftPM.productsDirectory),
            access: .readOnly)
        guard !mounts.contains(where: { $0.target == assemblerProducts.target }) else {
            throw PublishLinuxRuntimeArtifactFailure.conflictingMount(
                assemblerProducts.target)
        }
        mounts.append(assemblerProducts)
        let artifactMount = OCIMount(
            boundedExport: artifactRoot,
            target: containerPath(artifactRoot))
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
            workingDirectory: containerPath(runtimeSwiftPM.context.packageRoot),
            hostWorkingDirectory: runtimeSwiftPM.context.packageRoot,
            mounts: mounts,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .build,
            containerEnvironment: containerEnvironment,
            command: assemblerOCI.commandPrefix + [
                containerPath(
                    assemblerSwiftPM.executable("nucleus-linux-runtime-publisher")),
                containerPath(runtimeSwiftPM.productsDirectory),
                containerPath(artifactRoot.appending("current")),
                containerPath(generationsRoot),
                containerPath(packageManifestsRoot),
                String(rollbackGenerationCount),
                containerPath(sessionPackage),
                "release",
                architecture.rawValue,
                // The sysroot the payload is assembled from, in search order.
                // Named rather than inherited from the build environment: what
                // a package ships is not what the build linked against.
                targetLibraryRoots.map(\.string).joined(separator: ":"),
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
