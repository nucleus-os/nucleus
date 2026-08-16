import ChromiumColliderRecipe
import ColliderCore
import Foundation
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
    private let productStoreRoot: FilePath
    private let architecture: PlatformArchitecture

    package var identity: Identity { Identity(execution: execution) }
    package var requirements: ActionRequirements { pipeline.requirements }

    package init(
        architecture: PlatformArchitecture,
        sourceSnapshot: FilePath,
        runtimeArtifactRoot: FilePath,
        browser: ChromiumColliderRecipe.PackageInput,
        assemblerSwiftPM: SwiftPMInvocation,
        outputRoot: FilePath,
        productStoreRoot: FilePath,
        producerRunner: RunnerPlatform,
        environment: [String: String]
    ) throws {
        self.outputRoot = outputRoot
        self.productStoreRoot = productStoreRoot
        self.architecture = architecture
        guard case .oci(let assemblerOCI) = assemblerSwiftPM.context.execution else {
            throw LinuxNativePackageExecutionFailure.requiresOCI
        }
        let repositoryRoot = assemblerSwiftPM.context.packageRoot
            .removingLastComponent()
        var mounts = assemblerOCI.mounts.filter {
            $0.source != repositoryRoot
        }
        let sourceSnapshotRoot = sourceSnapshot.removingLastComponent()
        try appendMount(
            OCIMount(
                source: sourceSnapshotRoot,
                target: sourceSnapshotRoot.string,
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: assemblerSwiftPM.productsDirectory,
                target: assemblerSwiftPM.productsDirectory.string,
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: runtimeArtifactRoot,
                target: runtimeArtifactRoot.string,
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: browser.publication.distributionRoot,
                target: browser.publication.distributionRoot.string,
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: browser.publication.packageInputRoot,
                target: browser.publication.packageInputRoot.string,
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(
                source: nativeBuilderIdentityMountRoot(assemblerOCI.imageID),
                target: nativeBuilderIdentityMountRoot(assemblerOCI.imageID).string,
                access: .readOnly),
            to: &mounts)
        try appendMount(
            OCIMount(boundedExport: outputRoot, target: outputRoot.string),
            to: &mounts)
        try appendMount(
            OCIMount(
                boundedExport: productStoreRoot,
                target: productStoreRoot.string),
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
            workingDirectory: outputRoot.string,
            hostWorkingDirectory: outputRoot,
            mounts: mounts,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .build,
            containerEnvironment: containerEnvironment,
            command: assemblerOCI.commandPrefix + [
                "fakeroot",
                assembler.string,
                "packages",
                sourceSnapshot.string,
                runtimeArtifactRoot.string,
                browser.publication.distributionRoot.string,
                browser.publication.packageInputRoot.string,
                outputRoot.string,
                productStoreRoot.string,
                architecture.rawValue,
                assembler.string,
                producerRunner.operatingSystem.rawValue,
                producerRunner.architecture.rawValue,
                assemblerOCI.imageID.string,
            ],
            environment: environment,
            output: .logged)
        pipeline = try OCIExecutionPipeline([execution])
    }

    package func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(outputRoot)
        try context.files.createDirectory(productStoreRoot)
        try await context.containers.run(execution)
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateLinuxNativePackagePublication(
            architecture: architecture,
            outputRoot: outputRoot,
            productStoreRoot: productStoreRoot,
            files: files)
    }
}

package func nativeBuilderIdentityMountRoot(_ imageID: FilePath) -> FilePath {
    imageID.removingLastComponent()
}

private func appendMount(
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

    package var description: String {
        switch self {
        case .requiresOCI:
            "Linux native package assembly requires the Linux OCI builder"
        case .conflictingMount(let target):
            "Linux native package assembly has conflicting OCI mount '\(target)'"
        }
    }
}
