import ChromiumColliderRecipe
import ColliderCore
import Foundation
import LinuxPackageContracts
import SystemPackage

package struct PackageLinuxRuntimeAdapterAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let execution: OCIExecution
        let payloadPublicationRoot: FilePath

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
            encoder.append(path: payloadPublicationRoot)
        }
    }

    package static let kind: ActionKind = "linux.package-runtime-adapter"

    private let execution: OCIExecution
    private let pipeline: OCIExecutionPipeline
    private let payloadPublicationRoot: FilePath
    private let outputRoot: FilePath
    private let payloadView: FilePath
    private let stageObservationReport: FilePath
    private let family: LinuxDistributionFamily
    private let package: LinuxNativePackageName

    package var identity: Identity {
        Identity(
            execution: execution,
            payloadPublicationRoot: payloadPublicationRoot)
    }

    package var requirements: ActionRequirements {
        var effects = pipeline.requirements.effects
        effects.append(
            ActionEffect(.read, scope: .input(payloadPublicationRoot)))
        return ActionRequirements(
            effects: effects,
            lane: pipeline.requirements.lane,
            executionPlatform: pipeline.requirements.executionPlatform,
            artifactTarget: pipeline.requirements.artifactTarget)
    }

    package init(
        architecture: PlatformArchitecture,
        family: LinuxDistributionFamily,
        package: LinuxNativePackageName,
        runtimeArtifactRoot: FilePath,
        browser: ChromiumColliderRecipe.PackageInput,
        payloadPublicationRoot: FilePath,
        assemblerSwiftPM: SwiftPMInvocation,
        outputRoot: FilePath,
        environment: [String: String]
    ) throws {
        self.payloadPublicationRoot = payloadPublicationRoot
        self.outputRoot = outputRoot
        self.family = family
        self.package = package
        payloadView = outputRoot.appending(".payload-view")
        stageObservationReport = outputRoot.appending(".stage-observations.json")
        guard case .oci(let assemblerOCI) = assemblerSwiftPM.context.execution else {
            throw LinuxNativePackageExecutionFailure.requiresOCI
        }
        let repositoryRoot = assemblerSwiftPM.context.packageRoot
            .removingLastComponent()
        var mounts = assemblerOCI.mounts.filter { $0.source != repositoryRoot }
        for mount in [
            OCIMount(
                source: assemblerSwiftPM.productsDirectory,
                target: assemblerSwiftPM.productsDirectory.string,
                access: .readOnly),
            OCIMount(
                source: runtimeArtifactRoot,
                target: runtimeArtifactRoot.string,
                access: .readOnly),
            OCIMount(
                source: browser.publication.distributionRoot,
                target: browser.publication.distributionRoot.string,
                access: .readOnly),
            OCIMount(
                source: browser.publication.packageInputRoot,
                target: browser.publication.packageInputRoot.string,
                access: .readOnly),
            OCIMount(boundedExport: outputRoot, target: outputRoot.string),
        ] {
            try appendMount(mount, to: &mounts)
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
            hostname:
                "na-\(architecture.rawValue)-\(family.rawValue.prefix(1))-"
                + package.rawValue,
            workingDirectory: outputRoot.string,
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
                assembler.string,
                "adapter",
                runtimeArtifactRoot.string,
                browser.publication.distributionRoot.string,
                browser.publication.packageInputRoot.string,
                payloadView.string,
                outputRoot.string,
                architecture.rawValue,
                family.rawValue,
                package.rawValue,
                assembler.string,
                stageObservationReport.string,
            ],
            environment: environment,
            output: .logged)
        pipeline = try OCIExecutionPipeline([execution])
    }

    package func execute(in context: ActionContext) async throws {
        try validateLinuxNativePackagePayloadPublication(
            payloadPublicationRoot,
            package: package,
            files: context.files)
        let target = try context.files.readSymbolicLink(
            payloadPublicationRoot.appending("current"))
        let payload = payloadPublicationRoot.appending(target)
        let payloadByteCount = try linuxNativePackageLogicalByteCount(
            at: payload,
            files: context.files)
        try context.files.createDirectory(outputRoot)
        try context.files.remove(payloadView)
        try context.files.remove(stageObservationReport)
        let viewStart = ContinuousClock().now
        try context.files.copyTree(from: payload, to: payloadView)
        context.observations.record(
            ActionStageObservation(
                name: LinuxNativePackageChildStage.familyViewConstruction
                    .observationName(package: package, family: family),
                durationNanoseconds: elapsedNanoseconds(since: viewStart),
                inputByteCount: payloadByteCount,
                outputByteCount: payloadByteCount))
        defer {
            try? context.files.remove(payloadView)
            try? context.files.remove(stageObservationReport)
        }
        try await context.containers.run(execution)
        let observations = try JSONDecoder().decode(
            [ActionStageObservation].self,
            from: Data(context.files.read(stageObservationReport)))
        let expectedTopLevel = [
            family.assemblyStage.observationName,
            family.validationStage.observationName,
        ]
        guard observations.prefix(2).map(\.name) == expectedTopLevel else {
            throw LinuxNativePackageExecutionFailure.invalidStageObservationReport
        }
        for observation in observations {
            context.observations.record(observation)
        }
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateLinuxNativePackageAdapterPublication(
            outputRoot,
            family: family,
            package: package,
            files: files)
    }
}
