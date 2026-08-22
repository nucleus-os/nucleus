import ColliderCore
import SystemPackage

/// Generates the AVB signing identity inside the builder image.
///
/// The identity is generated once and then consumed by signing and validation,
/// which run in containers. Generating it on the host meant one chain used two
/// openssl implementations: macOS resolves the name to LibreSSL, the image to
/// OpenSSL, and they disagree about flags. Worse, the host tool is resolved
/// from `PATH`, so the task's identity depended on which account planned it.
/// The image pins one implementation for the whole chain.
package struct PublishAOSPSigningIdentityAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
        }
    }

    package static let kind: ActionKind = "android-runtime.publish-aosp-signing-identity"

    private let execution: OCIExecution
    private let pipeline: OCIExecutionPipeline
    private let destination: FilePath

    package var identity: Identity { Identity(execution: execution) }
    package var requirements: ActionRequirements { pipeline.requirements }

    package init(
        preparation: AOSPSigningIdentityPreparation,
        assemblerSwiftPM: SwiftPMInvocation,
        placement: IdentityPathMap
    ) throws {
        destination = preparation.destination
        guard case .oci(let assemblerOCI) = assemblerSwiftPM.context.execution else {
            throw AOSPSigningIdentityExecutionFailure.requiresOCI
        }

        // Every path this execution names is the path the container sees.
        let containerPath = placement.executionPath
        let identityRoot = preparation.destination.removingLastComponent()
        var mounts = assemblerOCI.mounts
        for mount in [
            OCIMount(
                source: assemblerSwiftPM.productsDirectory,
                target: containerPath(assemblerSwiftPM.productsDirectory),
                access: .readOnly),
            OCIMount(boundedExport: identityRoot, target: containerPath(identityRoot)),
        ] {
            guard !mounts.contains(where: { $0.target == mount.target }) else {
                throw AOSPSigningIdentityExecutionFailure.conflictingMount(mount.target)
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
            artifactTarget: .linuxARM64,
            imageID: assemblerOCI.imageID,
            hostname: "nucleus-aosp-signing-identity",
            workingDirectory: containerPath(identityRoot),
            hostWorkingDirectory: identityRoot,
            mounts: mounts,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .build,
            containerEnvironment: containerEnvironment,
            command: assemblerOCI.commandPrefix + [
                containerPath(tool),
                "signing-identity",
                containerPath(preparation.destination),
                preparation.subject,
            ],
            environment: preparation.environment,
            output: .logged)
        pipeline = try OCIExecutionPipeline([execution])
    }

    package func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(destination.removingLastComponent())
        try await context.containers.run(execution)
    }
}

package enum AOSPSigningIdentityExecutionFailure: Error, CustomStringConvertible,
    Sendable
{
    case requiresOCI
    case conflictingMount(String)

    package var description: String {
        switch self {
        case .requiresOCI:
            "AOSP signing identity generation requires an OCI assembler context"
        case .conflictingMount(let target):
            "AOSP signing identity generation has conflicting OCI mount '\(target)'"
        }
    }
}
