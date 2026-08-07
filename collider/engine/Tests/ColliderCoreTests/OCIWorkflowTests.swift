import ColliderCore
import ColliderEngine
import ColliderPersistence
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ColliderAppleContainer
@testable import ColliderRuntime

@Test func nativeAppleContainerFlagsEnforceTheHermeticBoundary() throws {
    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxX86_64,
        imageID: FilePath("/var/nucleus/image-id"),
        hostname: "fixture-builder",
        workingDirectory: "/src",
        hostWorkingDirectory: FilePath("/var/nucleus"),
        mounts: [
            OCIMount(
                source: FilePath("/var/nucleus/source"),
                target: "/src",
                access: .readOnly),
            OCIMount(
                source: FilePath("/var/nucleus/output"),
                target: "/build",
                access: .readWrite),
        ],
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        intelBinaryTranslationPolicy: .required,
        resourceLimits: .build,
        containerEnvironment: ["BUILD_MODE": "fixture"],
        command: ["fixture", "compile"],
        environment: [:],
        output: .logged)

    let flags = appleContainerFlags(
        execution,
        name: "fixture-builder-id",
        temporaryDirectory: FilePath("/var/nucleus/temporary"))
    try flags.management.validate()

    #expect(flags.management.networks == ["collider-internal"])
    #expect(flags.management.platform == "linux/arm64")
    #expect(flags.management.dnsDisabled)
    #expect(flags.management.capDrop == ["ALL"])
    #expect(flags.management.readOnly)
    #expect(flags.management.rosetta)
    #expect(flags.management.name == "fixture-builder-id")
    #expect(flags.management.tmpFs == ["/home/collider"])
    #expect(flags.process.uid == 1000)
    #expect(flags.process.gid == 1000)
    #expect(flags.process.env == ["BUILD_MODE=fixture"])
    #expect(flags.process.cwd == "/src")
    #expect(
        flags.process.ulimits == [
            "nproc=32768:32768",
            "nofile=131072:131072",
        ])
    #expect(flags.resource.cpus == 20)
    #expect(flags.resource.memory == String(96 * 1_024 * 1_024 * 1_024))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=/var/nucleus/source,target=/src,readonly"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=/var/nucleus/output,target=/build"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=/var/nucleus/temporary,target=/tmp"))

    let alternateConfiguration = OCIRuntimeConfiguration(
        externalNetwork: "alternate-external",
        isolatedNetwork: "alternate-isolated",
        guestHome: "/home/alternate",
        managedLabels: ["example.alternate.managed=true"],
        loggerLabel: "example.alternate.container")
    let alternateFlags = appleContainerFlags(
        execution,
        name: "alternate-builder-id",
        temporaryDirectory: nil,
        configuration: alternateConfiguration)
    #expect(alternateFlags.management.networks == ["alternate-isolated"])
    #expect(alternateFlags.management.labels == ["example.alternate.managed=true"])
    #expect(alternateFlags.management.tmpFs.contains("/home/alternate"))
    #expect(alternateFlags.management.networks != flags.management.networks)

    let externalExecution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: FilePath("/var/nucleus/image-id"),
        hostname: "fixture-download",
        workingDirectory: "/src",
        hostWorkingDirectory: FilePath("/var/nucleus"),
        mounts: [],
        networkPolicy: .externalEnabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .parallelBuild,
        containerEnvironment: [:],
        command: ["download"],
        environment: [:],
        output: .logged)
    let externalFlags = appleContainerFlags(
        externalExecution,
        name: "fixture-download-id",
        temporaryDirectory: nil)
    #expect(externalFlags.management.networks == ["default"])
    #expect(!externalFlags.management.dnsDisabled)
}

@Test func ociExecutionRejectsDuplicateMountTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-build-container-invalid-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true)
    let imageID = root.appendingPathComponent("image-id")
    try Data(("sha256:" + String(repeating: "b", count: 64) + "\n").utf8)
        .write(to: imageID)

    await #expect(throws: RuntimeFailure.self) {
        try await ColliderRuntime().runOCI(
            OCIExecution(
                executionPlatform: .linuxAMD64OCI,
                artifactTarget: .linuxX86_64,
                imageID: FilePath(imageID.path),
                hostname: "fixture-builder",
                workingDirectory: "/src",
                hostWorkingDirectory: FilePath(root.path),
                mounts: [
                    OCIMount(
                        source: FilePath(root.path),
                        target: "/src",
                        access: .readOnly),
                    OCIMount(
                        source: FilePath(root.path),
                        target: "/src",
                        access: .readOnly),
                ],
                networkPolicy: .externalDisabled,
                userPolicy: .builder,
                capabilityPolicy: .dropAll,
                privilegePolicy: .prohibitAcquisition,
                processFilesystemPolicy: .standard,
                resourceLimits: .build,
                containerEnvironment: [:],
                command: ["fixture"],
                environment: [:],
                output: .logged),
            stage: TaskID(rawValue: "fixture.invalid-build-container"))
    }
}

@Test func runtimeExecutesOCIThroughTheInjectedBackend() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-oci-backend-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true)
    let context = root.appendingPathComponent("context", isDirectory: true)
    let output = root.appendingPathComponent("output", isDirectory: true)
    let temporary = root.appendingPathComponent("temporary", isDirectory: true)
    try FileManager.default.createDirectory(
        at: context,
        withIntermediateDirectories: true)
    let containerFile = context.appendingPathComponent("Containerfile")
    try Data(
        ("FROM debian@sha256:" + String(repeating: "a", count: 64) + "\n").utf8
    ).write(to: containerFile)

    let backend = RecordingOCIBackend()
    let configuration = OCIRuntimeConfiguration(
        externalNetwork: "fixture-external",
        isolatedNetwork: "fixture-isolated",
        guestHome: "/home/fixture",
        managedLabels: ["example.fixture.managed=true"],
        loggerLabel: "example.fixture")
    let runtime = ColliderRuntime(
        downloadCacheRoot: FilePath(root.appendingPathComponent("cache").path),
        ociConfiguration: configuration,
        ociBackend: backend)
    let imageID = root.appendingPathComponent("image-id")
    let preparation = OCIImagePreparation(
        executionPlatform: .linuxARM64OCI,
        context: FilePath(context.path),
        containerFile: FilePath(containerFile.path),
        imageID: FilePath(imageID.path),
        imageName: "localhost/fixture",
        environment: [:])
    try await runtime.prepareOCIImage(
        preparation,
        stage: TaskID(rawValue: "fixture.prepare"))

    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: FilePath(imageID.path),
        hostname: "fixture",
        workingDirectory: "/src",
        hostWorkingDirectory: FilePath(root.path),
        mounts: [
            OCIMount(
                source: FilePath(context.path),
                target: "/src",
                access: .readOnly),
            OCIMount(
                source: FilePath(output.path),
                target: "/output",
                access: .readWrite),
        ],
        temporaryDirectory: FilePath(temporary.path),
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .build,
        containerEnvironment: [:],
        command: ["true"],
        environment: [:],
        output: .captured(limit: 128))
    let observations = try await runtime.execute(
        try fixtureOCIExecutionAction(execution),
        stage: TaskID(rawValue: "fixture.execute"))

    #expect(observations.containerExecutions.count == 1)
    #expect(observations.containerExecutions.first?.status == 0)
    #expect(observations.containerExecutions.first?.artifactTarget == .linuxARM64)
    #expect(await backend.preparation?.imageName == "localhost/fixture")
    let request = try #require(await backend.request)
    #expect(request.execution.command == ["true"])
    #expect(request.configuration == configuration)
    #expect(request.stage == TaskID(rawValue: "fixture.execute"))
    #expect(request.temporaryDirectory != nil)
    #expect(
        request.temporaryDirectory.map {
            !FileManager.default.fileExists(atPath: $0.string)
        } == true)
    await request.cancellation.interruptAll()
    #expect(await runtime.cancellation.wasInterrupted())

    #expect(try await runtime.ociRuntimeHealth().apiServerAppName == "fixture")
    #expect(
        try await runtime.ociRuntimeNetwork(named: "fixture-network").name
            == "fixture-network")
    #expect(try await runtime.ociRuntimeDiskUsage().reclaimableBytes == 6)
    try await runtime.pruneOCIImages()
    #expect(await backend.pruned)
}

@Test func externalCatalogPlansExecutesAndRecordsHostAndOCIWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-external-catalog-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let imageID = root.appending("image-id")
    let hostTaskID = TaskID(rawValue: "external.prepare-image")
    let ociTaskID = TaskID(rawValue: "external.execute-container")
    let componentID = ComponentID(rawValue: "fixture")
    let imageDigest = "sha256:" + String(repeating: "c", count: 64)
    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: imageID,
        hostname: "external-catalog",
        workingDirectory: "/work",
        hostWorkingDirectory: root,
        mounts: [],
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .build,
        containerEnvironment: [:],
        command: ["true"],
        environment: [:],
        output: .logged)
    let component = try ComponentDefinition(
        descriptor: ComponentDescriptor(
            id: componentID,
            canonicalName: "external",
            directoryName: "external"),
        tasks: [
            TaskDeclaration(
                id: hostTaskID,
                component: componentID,
                outputs: [OutputDeclaration(path: imageID, validation: .regularFile)],
                action: try fixtureWriteAction(imageID, bytes: Array(imageDigest.utf8))),
            TaskDeclaration(
                id: ociTaskID,
                component: componentID,
                dependencies: [hostTaskID],
                action: try fixtureOCIExecutionAction(execution)),
        ],
        entrypoints: [
            ComponentEntrypoint(id: .build, roots: [ociTaskID])
        ])
    let request = ComponentEntrypointRequest(spelling: "external", entrypoint: .build)
    let catalog = ComponentCatalog(
        components: [component],
        publicEntrypoints: [request])
    let registry = RunRegistry(root: root.appending("history"))
    let run = try await registry.begin(command: ["external-collider", "build"])
    let backend = RecordingOCIBackend()
    let runtime = ColliderRuntime(
        logging: CommandLogging(registry: registry, run: run),
        downloadCacheRoot: root.appending("downloads"),
        ociConfiguration: .engineDefault,
        ociBackend: backend)

    let report = try await ColliderEngine(runtime: runtime).execute(
        catalog: catalog,
        requests: [request],
        stateRoot: root.appending("state"),
        run: run,
        registry: registry)
    try await registry.finish(run, status: .succeeded)

    #expect(report.executed == [hostTaskID, ociTaskID])
    #expect(try String(contentsOfFile: imageID.string, encoding: .utf8) == imageDigest)
    #expect(await backend.request?.execution.command == ["true"])
    let manifest = try JSONDecoder().decode(
        RunManifest.self,
        from: Data(
            contentsOf: URL(fileURLWithPath: run.directory.appending("manifest.json").string)))
    #expect(manifest.status == .succeeded)
    #expect(manifest.tasks?[hostTaskID.rawValue]?.outcome == .executed)
    #expect(manifest.tasks?[ociTaskID.rawValue]?.outcome == .executed)
    #expect(
        manifest.tasks?[ociTaskID.rawValue]?.observations?.containerExecutions.count == 1)
}

@Test func appleContainerCleanupDeletesAndVerifiesTheExactName() async throws {
    let fixture = AppleContainerCleanupFixture(remainingChecks: 0)
    let name = "fixture-cleanup-exact"
    let cleanup = AppleContainerCleanup(
        name: name,
        delete: { await fixture.recordDelete(name) },
        exists: { await fixture.exists() })

    async let first: Void = cleanup.deleteAndVerify()
    async let second: Void = cleanup.deleteAndVerify()
    _ = try await (first, second)

    let deletedNames = await fixture.deletedNames
    #expect(deletedNames == [name])
}

@Test func appleContainerCleanupRetriesUntilTheNameDisappears() async throws {
    let fixture = AppleContainerCleanupFixture(remainingChecks: 1)
    let name = "fixture-cleanup-retry"
    let cleanup = AppleContainerCleanup(
        name: name,
        delete: { await fixture.recordDelete(name) },
        exists: { await fixture.exists() })

    try await cleanup.deleteAndVerify()

    let deletedNames = await fixture.deletedNames
    #expect(deletedNames == [name, name])
}

@Test func appleContainerCleanupFinishesAfterCallerCancellation() async throws {
    let fixture = AppleContainerCleanupFixture(remainingChecks: 1)
    let name = "fixture-cleanup-cancellation"
    let cleanup = AppleContainerCleanup(
        name: name,
        delete: { await fixture.recordDelete(name) },
        exists: { await fixture.exists() })
    let operation = Task {
        try await cleanup.deleteAndVerify()
    }

    try await ContinuousClock().sleep(for: .milliseconds(20))
    operation.cancel()
    try await operation.value

    #expect(await fixture.deletedNames == [name, name])
}

@Test func runtimeInterruptionImmediatelyInvokesLateCleanupRegistration() async {
    let cancellation = RuntimeCancellation()
    let invocationCount = Mutex(0)
    await cancellation.interruptAll()

    let registration = await cancellation.register {
        invocationCount.withLock { $0 += 1 }
    }
    await cancellation.cancelAll()
    await cancellation.unregister(registration)

    #expect(invocationCount.withLock { $0 } == 1)
}

@Test func appleContainerSuspensionStopsAndPreservesTheExactBuilder() async throws {
    let fixture = AppleContainerSuspensionFixture()
    let name = "fixture-builder"
    let suspension = AppleContainerSuspension(
        name: name,
        stop: { await fixture.stop(name) },
        status: { await fixture.isStopped() ? .stopped : .running })

    try await suspension.stopAndVerify()

    #expect(await fixture.stoppedNames == [name])
    #expect(await fixture.isStopped())
}

@Test func ociPolicyValidationIsBackendIndependent() throws {
    try validateOCIPlatform(.linuxAMD64OCI)
    try validateOCIPlatform(.linuxARM64OCI)
    #expect(throws: OCIExecutorFailure.self) {
        try validateOCIPlatform(
            ExecutionPlatform(
                environment: .native,
                operatingSystem: .linux,
                architecture: .arm64))
    }
}

@Test func taskPlanningReportsIndependentPlatformCoordinates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-oci-plan-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(
        at: bin, withIntermediateDirectories: true)
    let container = bin.appendingPathComponent("container")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: container)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: container.path)

    let taskID = TaskID(rawValue: "fixture.oci-plan")
    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .androidX86_64(apiLevel: 37),
        imageID: FilePath(root.appendingPathComponent("image-id").path),
        hostname: "fixture-builder",
        workingDirectory: "/source",
        hostWorkingDirectory: FilePath(root.path),
        mounts: [],
        temporaryDirectory: FilePath(
            root.appendingPathComponent("temporary").path),
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .build,
        containerEnvironment: [:],
        command: ["true"],
        environment: ["PATH": bin.path],
        output: .logged)
    let graph = try TaskGraph([
        TaskDeclaration(
            id: taskID,
            component: ComponentID(rawValue: "fixture"),
            action: try fixtureOCIExecutionAction(execution))
    ])

    let report = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: graph,
        selected: [taskID],
        stateRoot: FilePath(root.appendingPathComponent("state").path),
        options: TaskExecutionOptions(dryRun: true))
    let coordinates = try #require(report.plan.first?.coordinates)

    #expect(coordinates.runner == .current)
    #expect(coordinates.execution == .linuxARM64OCI)
    #expect(coordinates.backend == .appleContainer)
    #expect(coordinates.artifact == .androidX86_64(apiLevel: 37))
    #expect(report.executed.isEmpty)
}

@Test func appleExecutorTranslatesTheHermeticOCIContract() throws {
    let root = FilePath("/var/nucleus")
    let preparation = OCIImagePreparation(
        executionPlatform: .linuxARM64OCI,
        context: root.appending("context"),
        containerFile: root.appending("context/Containerfile"),
        imageID: root.appending("image-id"),
        imageName: "localhost/nucleus-build",
        environment: ["PATH": "/usr/bin"])
    let buildArguments = appleContainerBuildArguments(preparation)
    #expect(buildArguments.contains("linux/arm64"))
    #expect(buildArguments.contains("--pull"))
    #expect(buildArguments.contains("plain"))
    #expect(buildArguments.contains(preparation.imageName))
    #expect(buildArguments.contains(preparation.containerFile.string))
    #expect(buildArguments.last == preparation.context.string)

    let digest = "sha256:" + String(repeating: "d", count: 64)
    let name = "localhost/nucleus-build:latest"

    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxX86_64,
        imageID: root.appending("image-id"),
        hostname: "fixture-build",
        workingDirectory: "/source",
        hostWorkingDirectory: root,
        mounts: [
            OCIMount(
                source: root.appending("source"),
                target: "/source",
                access: .readOnly),
            OCIMount(
                source: root.appending("output"),
                target: "/output",
                access: .readWrite),
        ],
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        intelBinaryTranslationPolicy: .required,
        resourceLimits: OCIResourceLimits(
            cpuCount: 16,
            memoryBytes: 88 * 1_024 * 1_024 * 1_024,
            processCount: 32_768),
        containerEnvironment: ["LANG": "C.UTF-8"],
        command: ["ninja", "all"],
        environment: ["PATH": "/usr/bin"],
        output: .logged)
    let executionName = appleContainerName(for: execution)
    #expect(
        executionName.hasPrefix("fixture-build-")
            && executionName != "fixture-build")
    let secondExecutionName = appleContainerName(for: execution)
    #expect(secondExecutionName != executionName)
    #expect(ociImageReference("\(name)\n\(digest)") == name)

    let flags = appleContainerFlags(
        execution,
        name: executionName,
        temporaryDirectory: nil)
    #expect(flags.management.rosetta)
    #expect(flags.management.networks == ["collider-internal"])
    #expect(flags.management.dnsDisabled)
    #expect(flags.management.capDrop == ["ALL"])
    #expect(flags.management.readOnly)
    #expect(flags.management.tmpFs.contains("/tmp"))
    #expect(flags.management.tmpFs.contains("/home/collider"))
    #expect(flags.resource.cpus == 16)
    #expect(flags.resource.memory == String(88 * 1_024 * 1_024 * 1_024))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=/var/nucleus/source,target=/source,readonly"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=/var/nucleus/output,target=/output"))

    let armExecution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: root.appending("arm-image-id"),
        hostname: "fixture-arm-build",
        workingDirectory: "/source",
        hostWorkingDirectory: root,
        mounts: [],
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .build,
        containerEnvironment: [:],
        command: ["uname", "-m"],
        environment: ["PATH": "/usr/bin"],
        output: .logged)
    let armFlags = appleContainerFlags(
        armExecution,
        name: appleContainerName(for: armExecution),
        temporaryDirectory: nil)
    #expect(armFlags.management.platform == "linux/arm64")
    #expect(!armFlags.management.rosetta)

    let untranslatedIntelArtifact = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxX86_64,
        imageID: root.appending("arm-image-id"),
        hostname: "fixture-intel-build",
        workingDirectory: "/source",
        hostWorkingDirectory: root,
        mounts: [],
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .build,
        containerEnvironment: [:],
        command: ["true"],
        environment: ["PATH": "/usr/bin"],
        output: .logged)
    let untranslatedFlags = appleContainerFlags(
        untranslatedIntelArtifact,
        name: appleContainerName(for: untranslatedIntelArtifact),
        temporaryDirectory: nil)
    #expect(!untranslatedFlags.management.rosetta)
}

private actor AppleContainerCleanupFixture {
    private var remainingChecks: Int
    private(set) var deletedNames: [String] = []

    init(remainingChecks: Int) {
        self.remainingChecks = remainingChecks
    }

    func recordDelete(_ name: String) {
        deletedNames.append(name)
    }

    func exists() -> Bool {
        guard remainingChecks > 0 else { return false }
        remainingChecks -= 1
        return true
    }
}

private actor AppleContainerSuspensionFixture {
    private var stopped = false
    private(set) var stoppedNames: [String] = []

    func stop(_ name: String) {
        stoppedNames.append(name)
        stopped = true
    }

    func isStopped() -> Bool {
        stopped
    }
}

private actor RecordingOCIBackend: OCIRuntimeBackend {
    private(set) var preparation: OCIImagePreparation?
    private(set) var request: OCIRuntimeExecutionRequest?
    private(set) var pruned = false

    func prepareImage(_ preparation: OCIImagePreparation) async throws -> String {
        self.preparation = preparation
        return
            preparation.imageName + "\nsha256:"
            + String(repeating: "b", count: 64)
    }

    func execute(
        _ request: OCIRuntimeExecutionRequest
    ) async throws -> CommandResult {
        self.request = request
        return CommandResult(status: 0, standardOutput: "fixture-output")
    }

    func health() async throws -> OCIRuntimeHealth {
        OCIRuntimeHealth(
            appRoot: URL(fileURLWithPath: "/fixture/app"),
            installRoot: URL(fileURLWithPath: "/fixture/install"),
            apiServerVersion: "fixture",
            apiServerCommit: "fixture",
            apiServerBuild: "fixture",
            apiServerAppName: "fixture")
    }

    func network(named name: String) async throws -> OCIRuntimeNetworkState {
        OCIRuntimeNetworkState(name: name, mode: "fixture")
    }

    func diskUsage() async throws -> OCIRuntimeDiskUsage {
        let usage = { (bytes: UInt64) in
            OCIRuntimeResourceUsage(
                active: 0,
                reclaimable: bytes,
                sizeInBytes: bytes,
                total: 1)
        }
        return OCIRuntimeDiskUsage(
            containers: usage(1),
            images: usage(2),
            volumes: usage(3))
    }

    func pruneImages() async throws {
        pruned = true
    }
}
