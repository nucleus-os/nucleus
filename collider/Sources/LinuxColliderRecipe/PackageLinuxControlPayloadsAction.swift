import ChromiumColliderRecipe
import ColliderCore
import Foundation
import LinuxPackageAssembly
import LinuxPackageContracts
import SystemPackage

package struct PackageLinuxControlPayloadsAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
        }
    }

    package static let kind: ActionKind = "linux.package-control-payloads"

    private let execution: OCIExecution
    private let pipeline: OCIExecutionPipeline
    private let payloadRoot: FilePath
    private let stageObservationReport: FilePath

    package var identity: Identity { Identity(execution: execution) }
    package var requirements: ActionRequirements { pipeline.requirements }

    package init(
        architecture: PlatformArchitecture,
        runtimeArtifactRoot: FilePath,
        browser: ChromiumColliderRecipe.PackageInput,
        assemblerSwiftPM: SwiftPMInvocation,
        payloadRoot: FilePath,
        placement: IdentityPathMap,
        environment: [String: String]
    ) throws {
        self.payloadRoot = payloadRoot
        let firstOutput = payloadRoot.appending(
            LinuxNativePackageName.controlOnly[0].rawValue)
        stageObservationReport = firstOutput.appending(
            ".control-stage-observations.json")
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
        ] {
            try appendMount(mount, to: &mounts)
        }
        for package in LinuxNativePackageName.controlOnly {
            let output = payloadRoot.appending(package.rawValue)
            try appendMount(
                OCIMount(boundedExport: output, target: containerPath(output)),
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
            hostname: "nucleus-control-payloads-\(architecture.rawValue)",
            workingDirectory: containerPath(firstOutput),
            hostWorkingDirectory: firstOutput,
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
                "control-payloads",
                containerPath(runtimeArtifactRoot),
                containerPath(browser.publication.distributionRoot),
                containerPath(browser.publication.packageInputRoot),
                containerPath(payloadRoot),
                architecture.rawValue,
                containerPath(stageObservationReport),
            ],
            environment: environment,
            output: .logged)
        pipeline = try OCIExecutionPipeline([execution])
    }

    package func execute(in context: ActionContext) async throws {
        for package in LinuxNativePackageName.controlOnly {
            try context.files.createDirectory(payloadRoot.appending(package.rawValue))
        }
        try context.files.remove(stageObservationReport)
        defer { try? context.files.remove(stageObservationReport) }
        try await context.containers.run(execution)
        let observations = try JSONDecoder().decode(
            [ActionStageObservation].self,
            from: Data(context.files.read(stageObservationReport)))
        let names = Set(observations.map(\.name))
        guard
            LinuxNativePackageName.controlOnly.allSatisfy({ package in
                names.contains(
                    LinuxNativePackageChildStage.payloadMaterialization
                        .observationName(package: package))
            })
        else {
            throw LinuxNativePackageExecutionFailure.invalidStageObservationReport
        }
        for observation in observations {
            context.observations.record(observation)
        }
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        for package in LinuxNativePackageName.controlOnly {
            try validateLinuxNativePackagePayloadPublication(
                payloadRoot.appending(package.rawValue),
                package: package,
                files: files)
        }
    }
}
