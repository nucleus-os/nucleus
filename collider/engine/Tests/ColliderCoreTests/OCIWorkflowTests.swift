import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

@Test func ociExecutionEnforcesTheRootlessOfflineBoundary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-build-container-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let output = root.appendingPathComponent("output", isDirectory: true)
    let temporary = root.appendingPathComponent("temporary", isDirectory: true)
    let report = root.appendingPathComponent("podman-arguments")
    let imageID = root.appendingPathComponent("image-id")
    try FileManager.default.createDirectory(
        at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: source, withIntermediateDirectories: true)
    try Data(
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$REPORT\"\n".utf8
    ).write(to: bin.appendingPathComponent("podman"))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: bin.appendingPathComponent("podman").path)
    try Data(("sha256:" + String(repeating: "a", count: 64) + "\n").utf8)
        .write(to: imageID)

    try await ColliderRuntime().runOCI(
        OCIExecution(
            executionPlatform: .linuxAMD64OCI,
            artifactTarget: .linuxX86_64,
            imageID: FilePath(imageID.path),
            hostname: "fixture-builder",
            workingDirectory: "/src",
            hostWorkingDirectory: FilePath(source.path),
            mounts: [
                OCIMount(
                    source: FilePath(source.path),
                    target: "/src",
                    access: .readOnly),
                OCIMount(
                    source: FilePath(output.path),
                    target: "/build",
                    access: .readWrite),
            ],
            temporaryDirectory: FilePath(temporary.path),
            networkPolicy: .externalDisabled,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .build,
            containerEnvironment: ["BUILD_MODE": "fixture"],
            command: ["fixture", "compile"],
            environment: [
                "PATH": bin.path,
                "REPORT": report.path,
            ],
            output: .logged),
        stage: TaskID(rawValue: "fixture.build-container"))

    let arguments = try String(contentsOf: report, encoding: .utf8)
        .split(whereSeparator: \.isNewline).map(String.init)
    #expect(arguments.contains("--network=none"))
    #expect(arguments.contains("--platform=linux/amd64"))
    #expect(arguments.contains("--userns=keep-id:uid=1000,gid=1000"))
    #expect(arguments.contains("--cap-drop=all"))
    #expect(arguments.contains("--security-opt=no-new-privileges"))
    #expect(arguments.contains("--read-only"))
    #expect(!arguments.contains("--tmpfs=/tmp:rw,nosuid,nodev,size=8g"))
    #expect(arguments.contains("BUILD_MODE=fixture"))
    #expect(arguments.contains("fixture"))
    #expect(arguments.contains("compile"))
    #expect(FileManager.default.fileExists(atPath: output.path))
    #expect(
        arguments.contains {
            $0.contains("src=\(source.path),target=/src,ro=true")
        })
    #expect(
        arguments.contains {
            $0.contains("src=\(output.path),target=/build,rw=true")
        })
    #expect(
        arguments.contains {
            $0.contains("src=\(temporary.path)/")
                && $0.contains("target=/tmp,rw=true")
        })
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .isEmpty)
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

@Test func executorResolutionSeparatesRunnerFromExecutionPlatform() throws {
    let linux = try OCIExecutorResolver.resolve(
        runner: RunnerPlatform(
            operatingSystem: .linux,
            architecture: .x86_64),
        executionPlatform: .linuxAMD64OCI)
    #expect(linux.backend == .podman)

    let macOS = try OCIExecutorResolver.resolve(
        runner: RunnerPlatform(
            operatingSystem: .macOS,
            architecture: .arm64),
        executionPlatform: .linuxAMD64OCI)
    #expect(macOS.backend == .appleContainer)

    let nativeARM64 = try OCIExecutorResolver.resolve(
        runner: RunnerPlatform(
            operatingSystem: .linux,
            architecture: .arm64),
        executionPlatform: .linuxARM64OCI)
    #expect(nativeARM64.backend == .podman)

    let macOSARM64 = try OCIExecutorResolver.resolve(
        runner: RunnerPlatform(
            operatingSystem: .macOS,
            architecture: .arm64),
        executionPlatform: .linuxARM64OCI)
    #expect(macOSARM64.backend == .appleContainer)

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
    let podman = bin.appendingPathComponent("podman")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: podman)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: podman.path)

    let taskID = TaskID(rawValue: "fixture.oci-plan")
    let execution = OCIExecution(
        executionPlatform: .linuxAMD64OCI,
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
            operation: .runOCI(execution))
    ])

    let report = try await ColliderRuntime().execute(
        graph: graph,
        selected: [taskID],
        stateRoot: FilePath(root.appendingPathComponent("state").path),
        options: TaskExecutionOptions(dryRun: true))
    let coordinates = try #require(report.plan.first?.coordinates)

    #expect(coordinates.runner == .current)
    #expect(coordinates.execution == .linuxAMD64OCI)
    #expect(coordinates.backend == .podman)
    #expect(coordinates.artifact == .androidX86_64(apiLevel: 37))
    #expect(report.executed.isEmpty)
}

@Test func appleExecutorTranslatesTheHermeticOCIContract() throws {
    let root = FilePath("/var/nucleus")
    let preparation = OCIImagePreparation(
        executionPlatform: .linuxAMD64OCI,
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
    #expect(build.arguments.contains("linux/amd64"))
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
        executionPlatform: .linuxAMD64OCI,
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
        resourceLimits: OCIResourceLimits(
            cpuCount: 16,
            memoryBytes: 88 * 1_024 * 1_024 * 1_024,
            processCount: 32_768),
        containerEnvironment: ["LANG": "C.UTF-8"],
        command: ["ninja", "all"],
        environment: ["PATH": "/usr/bin"],
        output: .logged)
    let command = try executor.runCommand(
        execution,
        imageID: "\(name)\n\(digest)",
        temporaryDirectory: nil)
    #expect(command.executable == .named("container"))
    #expect(command.arguments.contains("--rosetta"))
    #expect(
        command.arguments.contains(OCIBackendContract.appleOfflineNetwork))
    #expect(command.arguments.contains("--no-dns"))
    let nameIndex = try #require(command.arguments.firstIndex(of: "--name"))
    let executionName = command.arguments[nameIndex + 1]
    #expect(
        executionName.hasPrefix("fixture-build-")
            && executionName != "fixture-build")
    let secondCommand = try executor.runCommand(
        execution,
        imageID: "\(name)\n\(digest)",
        temporaryDirectory: nil)
    let secondNameIndex = try #require(
        secondCommand.arguments.firstIndex(of: "--name"))
    #expect(secondCommand.arguments[secondNameIndex + 1] != executionName)
    #expect(command.arguments.contains("ALL"))
    #expect(command.arguments.contains("--read-only"))
    #expect(command.arguments.contains("--tmpfs"))
    #expect(command.arguments.contains("16"))
    #expect(command.arguments.contains(String(88 * 1_024 * 1_024 * 1_024)))
    #expect(command.arguments.contains(name))
    #expect(!command.arguments.contains(digest))
    #expect(
        command.arguments.contains(
            "type=bind,source=/var/nucleus/source,target=/source,readonly"))
    #expect(
        command.arguments.contains(
            "type=bind,source=/var/nucleus/output,target=/output"))
    #expect(!command.arguments.contains(where: { $0.contains("podman") }))

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
    let armCommand = try executor.runCommand(
        armExecution,
        imageID: "\(name)\n\(digest)",
        temporaryDirectory: nil)
    #expect(armCommand.arguments.contains("linux/arm64"))
    #expect(!armCommand.arguments.contains("--rosetta"))
}
