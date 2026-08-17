import ChromiumColliderRecipe
import ColliderCore
import Foundation
import LinuxPackageAssembly
import LinuxPackageContracts
import SystemPackage

package struct PackageLinuxControlAdaptersAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let execution: OCIExecution

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(nested: OCIExecutionActionIdentity(execution))
        }
    }

    package static let kind: ActionKind = "linux.package-control-adapters"

    private let execution: OCIExecution
    private let pipeline: OCIExecutionPipeline
    private let payloadRoot: FilePath
    private let outputRoot: FilePath
    private let stageObservationReport: FilePath

    package var identity: Identity { Identity(execution: execution) }
    package var requirements: ActionRequirements { pipeline.requirements }

    package init(
        architecture: PlatformArchitecture,
        runtimeArtifactRoot: FilePath,
        browser: ChromiumColliderRecipe.PackageInput,
        payloadRoot: FilePath,
        assemblerSwiftPM: SwiftPMInvocation,
        outputRoot: FilePath,
        environment: [String: String]
    ) throws {
        self.payloadRoot = payloadRoot
        self.outputRoot = outputRoot
        let firstOutput = outputRoot.appending(
            "\(LinuxDistributionFamily.allCases[0].rawValue)/"
                + LinuxNativePackageName.controlOnly[0].rawValue)
        stageObservationReport = firstOutput.appending(
            ".control-stage-observations.json")
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
            OCIMount(
                source: payloadRoot,
                target: payloadRoot.string,
                access: .readOnly),
        ] {
            try appendMount(mount, to: &mounts)
        }
        for family in LinuxDistributionFamily.allCases {
            for package in LinuxNativePackageName.controlOnly {
                let output = outputRoot.appending(
                    "\(family.rawValue)/\(package.rawValue)")
                try appendMount(
                    OCIMount(boundedExport: output, target: output.string),
                    to: &mounts)
            }
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
            hostname: "nucleus-control-adapters-\(architecture.rawValue)",
            workingDirectory: firstOutput.string,
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
                assembler.string,
                "control-adapters",
                runtimeArtifactRoot.string,
                browser.publication.distributionRoot.string,
                browser.publication.packageInputRoot.string,
                outputRoot.string,
                architecture.rawValue,
                assembler.string,
                stageObservationReport.string,
            ],
            environment: environment,
            output: .logged)
        pipeline = try OCIExecutionPipeline([execution])
    }

    package func execute(in context: ActionContext) async throws {
        try preparePayloadViews(context: context)
        try context.files.remove(stageObservationReport)
        defer {
            removePayloadViews(files: context.files)
            try? context.files.remove(stageObservationReport)
        }
        try await context.containers.run(execution)
        let observations = try JSONDecoder().decode(
            [ActionStageObservation].self,
            from: Data(context.files.read(stageObservationReport)))
        let names = Set(observations.map(\.name))
        guard
            LinuxDistributionFamily.allCases.allSatisfy({ family in
                LinuxNativePackageName.controlOnly.allSatisfy { package in
                    names.contains(
                        LinuxNativePackageChildStage.assembly.observationName(
                            package: package,
                            family: family))
                        && names.contains(
                            LinuxNativePackageChildStage.validation.observationName(
                                package: package,
                                family: family))
                }
            })
        else {
            throw LinuxNativePackageExecutionFailure.invalidStageObservationReport
        }
        for observation in observations {
            context.observations.record(observation)
        }
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        for family in LinuxDistributionFamily.allCases {
            for package in LinuxNativePackageName.controlOnly {
                try validateLinuxNativePackageAdapterPublication(
                    adapterRoot(family: family, package: package),
                    family: family,
                    package: package,
                    files: files)
            }
        }
    }

    private func preparePayloadViews(context: ActionContext) throws {
        for package in LinuxNativePackageName.controlOnly {
            let publication = payloadRoot.appending(package.rawValue)
            try validateLinuxNativePackagePayloadPublication(
                publication,
                package: package,
                files: context.files)
            let target = try context.files.readSymbolicLink(
                publication.appending("current"))
            let payload = publication.appending(target)
            let byteCount = try linuxNativePackageLogicalByteCount(
                at: payload,
                files: context.files)
            for family in LinuxDistributionFamily.allCases {
                let output = adapterRoot(family: family, package: package)
                let view = output.appending(".payload-view")
                try context.files.createDirectory(output)
                try context.files.remove(view)
                let start = ContinuousClock().now
                try context.files.copyTree(from: payload, to: view)
                context.observations.record(
                    ActionStageObservation(
                        name: LinuxNativePackageChildStage.familyViewConstruction
                            .observationName(package: package, family: family),
                        durationNanoseconds: elapsedNanoseconds(since: start),
                        inputByteCount: byteCount,
                        outputByteCount: byteCount))
            }
        }
    }

    private func removePayloadViews(files: ActionFileSystem) {
        for family in LinuxDistributionFamily.allCases {
            for package in LinuxNativePackageName.controlOnly {
                try? files.remove(
                    adapterRoot(family: family, package: package)
                        .appending(".payload-view"))
            }
        }
    }

    private func adapterRoot(
        family: LinuxDistributionFamily,
        package: LinuxNativePackageName
    ) -> FilePath {
        outputRoot.appending("\(family.rawValue)/\(package.rawValue)")
    }
}
