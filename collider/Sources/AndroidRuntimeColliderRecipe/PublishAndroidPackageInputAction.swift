import ColliderCore
import SystemPackage

/// Materializes an Android native-package input inside the builder image.
///
/// The materialization itself is one native Linux action. A Linux host running
/// its own installed runtime executes it directly; every other host reaches it
/// the way the runtime publisher is reached, by running a small Linux tool that
/// re-enters the same action inside a container. The macOS builder has no other
/// route: the planner admits a native action only when the runner's operating
/// system matches, so without this the one Android step nothing containerized
/// could not be planned at all, and the package cohort that depends on it could
/// not be assembled.
package struct PublishAndroidPackageInputAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
        }
    }

    package static let kind: ActionKind = "android-runtime.publish-package-input"

    private let execution: OCIExecution
    private let pipeline: OCIExecutionPipeline
    private let output: FilePath
    private let runtimeScratch: FilePath

    package var identity: Identity { Identity(execution: execution) }
    package var requirements: ActionRequirements { pipeline.requirements }

    package init(
        runtimeSwiftPM: SwiftPMInvocation,
        assemblerSwiftPM: SwiftPMInvocation,
        architecture: PlatformArchitecture,
        targetLibraryRoots: [FilePath],
        aospGeneration: FilePath,
        aospSigningKey: FilePath,
        runtimeScratch: FilePath,
        output: FilePath,
        appArmorPolicy: FilePath,
        seccompPolicy: FilePath,
        placement: IdentityPathMap,
        environment: [String: String]
    ) throws {
        self.output = output
        self.runtimeScratch = runtimeScratch
        guard case .oci(let assemblerOCI) = assemblerSwiftPM.context.execution,
            case .oci(let runtimeOCI) = runtimeSwiftPM.context.execution
        else {
            throw AndroidPackageInputExecutionFailure.requiresOCI
        }

        // The sysroot this payload is assembled from has to be present, not
        // merely named. The assembler image mounts the checkout and the SwiftPM
        // overlay and nothing else, so the SDK arrives from the invocation that
        // built the products being staged — which is also what guarantees the
        // two agree on which SDK that is.
        let guestSDKDirectory = SwiftPMInvocation.ociSwiftSDKDirectory.string
        guard
            let swiftSDKMount = runtimeOCI.mounts.first(where: {
                $0.target == guestSDKDirectory
            })
        else {
            throw AndroidPackageInputExecutionFailure.missingTargetSDK(
                guestSDKDirectory)
        }

        // Every path this execution names is the path the container sees.
        let containerPath = placement.executionPath
        var mounts = assemblerOCI.mounts
        // The signing key is a file, and a mount names a directory, so its
        // holding directory crosses read-only. The key never leaves the
        // container: the tool derives its public half to verify the image
        // chain the AOSP build already signed.
        let signingKeyRoot = aospSigningKey.removingLastComponent()
        for mount in [
            swiftSDKMount,
            OCIMount(
                source: assemblerSwiftPM.productsDirectory,
                target: containerPath(assemblerSwiftPM.productsDirectory),
                access: .readOnly),
            OCIMount(
                source: runtimeSwiftPM.productsDirectory,
                target: containerPath(runtimeSwiftPM.productsDirectory),
                access: .readOnly),
            OCIMount(
                source: aospGeneration,
                target: containerPath(aospGeneration),
                access: .readOnly),
            OCIMount(
                source: signingKeyRoot,
                target: containerPath(signingKeyRoot),
                access: .readOnly),
            OCIMount(boundedExport: runtimeScratch, target: containerPath(runtimeScratch)),
            OCIMount(
                boundedExport: output.removingLastComponent(),
                target: containerPath(output.removingLastComponent())),
        ] {
            guard !mounts.contains(where: { $0.target == mount.target }) else {
                throw AndroidPackageInputExecutionFailure.conflictingMount(mount.target)
            }
            mounts.append(mount)
        }

        var containerEnvironment = assemblerOCI.containerEnvironment
        containerEnvironment["PATH"] =
            "/opt/swift/usr/bin:/usr/local/sbin:/usr/local/bin:"
            + "/usr/sbin:/usr/bin:/sbin:/bin"
        containerEnvironment["LD_LIBRARY_PATH"] = [
            assemblerOCI.containerEnvironment["LD_LIBRARY_PATH"],
            "/opt/swift/usr/lib/swift/linux",
        ].compactMap { $0 }.joined(separator: ":")

        let tool = assemblerSwiftPM.executable("nucleus-android-assembler")
        execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: architecture,
                abi: "glibc"),
            imageID: assemblerOCI.imageID,
            hostname: "nucleus-android-package-input-\(architecture.rawValue)",
            workingDirectory: containerPath(runtimeScratch),
            hostWorkingDirectory: runtimeScratch,
            mounts: mounts,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .build,
            containerEnvironment: containerEnvironment,
            command: assemblerOCI.commandPrefix + [
                containerPath(tool),
                "package-input",
                containerPath(runtimeSwiftPM.productsDirectory),
                containerPath(aospGeneration),
                containerPath(aospSigningKey),
                containerPath(output),
                containerPath(runtimeScratch),
                containerPath(appArmorPolicy),
                containerPath(seccompPolicy),
                architecture.rawValue,
                // Already guest paths: the sysroot is named where the
                // materialization will look for it, not where a host holds it.
                targetLibraryRoots.map(\.string).joined(separator: ":"),
            ],
            environment: environment,
            output: .logged)
        pipeline = try OCIExecutionPipeline([execution])
    }

    package func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(output.removingLastComponent())
        try context.files.createDirectory(runtimeScratch)
        try await context.containers.run(execution)
    }
}

package enum AndroidPackageInputExecutionFailure: Error, CustomStringConvertible,
    Sendable
{
    case requiresOCI
    case conflictingMount(String)
    case missingTargetSDK(String)

    package var description: String {
        switch self {
        case .requiresOCI:
            "Android package input assembly requires OCI runtime and assembler contexts"
        case .conflictingMount(let target):
            "Android package input assembly has conflicting OCI mount '\(target)'"
        case .missingTargetSDK(let target):
            "Android package input assembly found no target SDK mounted at '\(target)'"
        }
    }
}
