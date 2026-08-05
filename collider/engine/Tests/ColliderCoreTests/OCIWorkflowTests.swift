import ColliderCore
import ColliderEngine
import Foundation
import Synchronization
import SystemPackage
import Testing

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

    #expect(flags.management.networks == [OCIBackendContract.appleOfflineNetwork])
    #expect(flags.management.platform == "linux/arm64")
    #expect(flags.management.dnsDisabled)
    #expect(flags.management.capDrop == ["ALL"])
    #expect(flags.management.readOnly)
    #expect(flags.management.rosetta)
    #expect(flags.management.name == "fixture-builder-id")
    #expect(flags.management.tmpFs == ["/home/nucleus-build"])
    #expect(flags.process.uid == 1000)
    #expect(flags.process.gid == 1000)
    #expect(flags.process.env == ["BUILD_MODE=fixture"])
    #expect(flags.process.cwd == "/src")
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

@Test func executorResolutionSeparatesRunnerFromExecutionPlatform() throws {
    let macOS = try OCIExecutorResolver.resolve(
        runner: RunnerPlatform(
            operatingSystem: .macOS,
            architecture: .arm64),
        executionPlatform: .linuxAMD64OCI)
    #expect(macOS.backend == .appleContainer)

    let macOSARM64 = try OCIExecutorResolver.resolve(
        runner: RunnerPlatform(
            operatingSystem: .macOS,
            architecture: .arm64),
        executionPlatform: .linuxARM64OCI)
    #expect(macOSARM64.backend == .appleContainer)

    #expect(throws: OCIExecutorFailure.self) {
        try OCIExecutorResolver.resolve(
            runner: RunnerPlatform(
                operatingSystem: .linux,
                architecture: .arm64),
            executionPlatform: .linuxARM64OCI)
    }

    #expect(throws: OCIExecutorFailure.self) {
        try OCIExecutorResolver.resolve(
            runner: RunnerPlatform(
                operatingSystem: .macOS,
                architecture: .arm64),
            executionPlatform: ExecutionPlatform(
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
    let executor = AppleContainerExecutor()
    let build = try executor.buildImageCommand(
        preparation,
        candidate: root.appending("candidate"))
    #expect(build.executable == .named("container"))
    #expect(build.arguments.contains("linux/arm64"))
    #expect(build.arguments.contains("--pull"))
    #expect(!build.arguments.contains("--iidfile"))

    let digest = "sha256:" + String(repeating: "d", count: 64)
    let name = "localhost/nucleus-build:latest"
    let inspection = """
        [{"configuration":{"descriptor":{"digest":"\(digest)"},"name":"\(name)"}}]
        """
    #expect(
        try executor.imageIdentifier(
            candidate: root.appending("candidate"),
            inspectionOutput: inspection) == "\(name)\n\(digest)")
    #expect(executor.removeImageCommand(digest, preparation: preparation) == nil)

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
    let executionName = try executor.containerName(for: execution)
    #expect(
        executionName.hasPrefix("fixture-build-")
            && executionName != "fixture-build")
    let secondExecutionName = try executor.containerName(for: execution)
    #expect(secondExecutionName != executionName)
    #expect(appleImageReference("\(name)\n\(digest)") == name)

    let flags = appleContainerFlags(
        execution,
        name: executionName,
        temporaryDirectory: nil)
    #expect(flags.management.rosetta)
    #expect(flags.management.networks == [OCIBackendContract.appleOfflineNetwork])
    #expect(flags.management.dnsDisabled)
    #expect(flags.management.capDrop == ["ALL"])
    #expect(flags.management.readOnly)
    #expect(flags.management.tmpFs.contains("/tmp"))
    #expect(flags.management.tmpFs.contains("/home/nucleus-build"))
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
        name: try executor.containerName(for: armExecution),
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
        name: try executor.containerName(for: untranslatedIntelArtifact),
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
