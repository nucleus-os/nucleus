import ColliderCore
import Foundation
import ShellColliderRecipe
import SystemPackage

package struct QualifyLinuxRuntimePackagesAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let pipeline: OCIExecutionPipelineIdentity

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: pipeline)
        }
    }

    package static let kind: ActionKind = "linux.qualify-runtime-packages"

    private let architecture: PlatformArchitecture
    private let packagePublicationRoot: FilePath
    private let productStoreRoot: FilePath
    private let qualificationRoot: FilePath
    private let pipeline: OCIExecutionPipeline

    package init(
        architecture: PlatformArchitecture,
        packagePublicationRoot: FilePath,
        productStoreRoot: FilePath,
        assemblerSwiftPM: SwiftPMInvocation,
        qualificationRoot: FilePath,
        environment: [String: String]
    ) throws {
        self.architecture = architecture
        self.packagePublicationRoot = packagePublicationRoot
        self.productStoreRoot = productStoreRoot
        self.qualificationRoot = qualificationRoot
        guard case .oci(let assemblerOCI) = assemblerSwiftPM.context.execution else {
            throw LinuxNativePackageExecutionFailure.requiresOCI
        }
        let repositoryRoot = assemblerSwiftPM.context.packageRoot
            .removingLastComponent()
        var mounts = assemblerOCI.mounts.filter {
            $0.source != repositoryRoot
        }
        try appendQualificationMount(
            OCIMount(
                source: assemblerSwiftPM.productsDirectory,
                target: assemblerSwiftPM.productsDirectory.string,
                access: .readOnly),
            to: &mounts)
        try appendQualificationMount(
            OCIMount(
                source: packagePublicationRoot,
                target: packagePublicationRoot.string,
                access: .readOnly),
            to: &mounts)
        try appendQualificationMount(
            OCIMount(
                source: productStoreRoot,
                target: productStoreRoot.string,
                access: .readOnly),
            to: &mounts)
        try appendQualificationMount(
            OCIMount(
                source: nativeBuilderIdentityMountRoot(assemblerOCI.imageID),
                target: nativeBuilderIdentityMountRoot(assemblerOCI.imageID).string,
                access: .readOnly),
            to: &mounts)
        try appendQualificationMount(
            OCIMount(
                boundedExport: qualificationRoot,
                target: qualificationRoot.string),
            to: &mounts)

        var containerEnvironment = assemblerOCI.containerEnvironment
        containerEnvironment["PATH"] =
            "/opt/swift/usr/bin:/usr/local/sbin:/usr/local/bin:"
            + "/usr/sbin:/usr/bin:/sbin:/bin"
        containerEnvironment["LD_LIBRARY_PATH"] = [
            assemblerOCI.containerEnvironment["LD_LIBRARY_PATH"],
            "/opt/swift/usr/lib/swift/linux",
        ].compactMap { $0 }.joined(separator: ":")
        let qualifier = assemblerSwiftPM.executable(
            "nucleus-linux-package-qualifier")
        let assembler = assemblerSwiftPM.executable("nucleus-linux-assembler")
        let artifactTarget = ArtifactTarget(
            operatingSystem: .linux,
            architecture: architecture,
            abi: "glibc")
        pipeline = try OCIExecutionPipeline(
            LinuxDistributionFamily.allCases.map { family in
                OCIExecution(
                    executionPlatform: .linuxARM64OCI,
                    artifactTarget: artifactTarget,
                    imageID: assemblerOCI.imageID,
                    hostname:
                        "nucleus-package-qualification-\(architecture.rawValue)-"
                        + family.rawValue,
                    workingDirectory: qualificationRoot.string,
                    hostWorkingDirectory: qualificationRoot,
                    mounts: mounts,
                    userPolicy: OCIUserPolicy(userID: 0, groupID: 0),
                    capabilityPolicy: .dropAll,
                    privilegePolicy: .prohibitAcquisition,
                    processFilesystemPolicy: .writableRoot,
                    resourceLimits: OCIResourceLimits(
                        cpuCount: 4,
                        memoryBytes: 8 * 1_024 * 1_024 * 1_024,
                        processCount: 4_096),
                    containerEnvironment: containerEnvironment,
                    command: assemblerOCI.commandPrefix + [
                        qualifier.string,
                        family.rawValue,
                        architecture.rawValue,
                        packagePublicationRoot.string,
                        productStoreRoot.string,
                        qualificationRoot.string,
                        assembler.string,
                        assemblerOCI.imageID.string,
                    ],
                    environment: environment,
                    output: .logged)
            })
    }

    package var identity: Identity { Identity(pipeline: pipeline.identity) }
    package var requirements: ActionRequirements { pipeline.requirements }
    package var environment: [String: String] { pipeline.environment }

    package func execute(in context: ActionContext) async throws {
        try context.files.remove(qualificationRoot)
        try context.files.createDirectory(qualificationRoot)
        try await pipeline.execute(in: context)
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        let reports: [LinuxNativePackageLifecycleQualificationReport] =
            try LinuxDistributionFamily.allCases.map { family in
                try decodeQualificationJSON(
                    files.read(
                        qualificationRoot.appending("\(family.rawValue).json")))
            }
        guard reports.map(\.family) == LinuxDistributionFamily.allCases,
            reports.allSatisfy({ report in
                report.architecture == architecture
                    && report.operations == [
                        "install-old", "upgrade-new", "downgrade-old",
                        "remove-old",
                    ]
                    && report.lifecycleInvocations >= 4
            })
        else {
            throw LinuxNativePackageQualificationFailure(
                "lifecycle qualification is incomplete")
        }
        let publication = try currentPackagePublication(files: files)
        for report in reports {
            let expected = publication.products.filter {
                $0.family == report.family && $0.package != nil
            }.map(\.productArtifact).sorted {
                $0.rawValue.hexadecimal < $1.rawValue.hexadecimal
            }
            guard report.productionArtifacts == expected else {
                throw LinuxNativePackageQualificationFailure(
                    "qualification refers to a substituted production cohort")
            }
        }
    }

    private func currentPackagePublication(
        files: ActionFileSystem
    ) throws -> LinuxNativePackageCohortPublication {
        let current = packagePublicationRoot.appending("current")
        guard
            try files.metadataWithoutFollowingSymlinks(for: current)?.type
                == .symbolicLink
        else {
            throw LinuxNativePackageQualificationFailure(
                "package publication is missing")
        }
        return try decodeQualificationJSON(
            files.read(
                packagePublicationRoot.appending(
                    try files.readSymbolicLink(current)
                ).appending("linux-native-package-cohort.json")))
    }
}

private func appendQualificationMount(
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

private func decodeQualificationJSON<T: Decodable>(_ bytes: [UInt8]) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(bytes))
}

private struct LinuxNativePackageQualificationFailure: Error,
    CustomStringConvertible, Sendable
{
    let description: String

    init(_ description: String) {
        self.description =
            "Linux native package qualification failed: \(description)"
    }
}
