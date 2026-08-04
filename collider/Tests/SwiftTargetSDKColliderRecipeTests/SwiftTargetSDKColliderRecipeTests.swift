import ColliderCore
import ColliderRuntime
import Foundation
import SwiftTargetSDKColliderRecipe
import SystemPackage
import Testing

@Test func targetSDKGenerationBuildsBothLinuxArchitecturesOnARM64() async throws {
    let root = FilePath(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path)
    let inputsFile = root.appending("swift-sdk/target-sdk-inputs.json")
    let inputs = try SwiftTargetSDKInputs.load(from: inputsFile)
    let temporary = FilePath(
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path)
    let linuxTargets = inputs.linuxTargets.map { target in
        SwiftLinuxTargetBuildConfiguration(
            target: target,
            runtimeBuildWorkspace: temporary.appending(
                "runtime-\(target.architecture.rawValue)/build"),
            runtimeCompilerCache: temporary.appending(
                "runtime-\(target.architecture.rawValue)/ccache"),
            runtimeInstall: temporary.appending(
                "runtime-\(target.architecture.rawValue)/install"),
            sysroot: temporary.appending(
                "runtime-\(target.architecture.rawValue)/sysroot"))
    }
    let configuration = SwiftTargetSDKGenerationConfiguration(
        inputs: inputs,
        inputsFile: inputsFile,
        androidAPILevel: 24,
        downloadRoot: temporary.appending("downloads"),
        generatorSource: root.appending("swift-sdk/source/swift-sdk-generator"),
        generatorScratch: temporary.appending("generator"),
        sourceWorkspace: root.appending("swift-sdk/source"),
        sourceID: "fixture-source-id",
        runtimeBuilderContext: root.appending(
            "swift-sdk/runtime-build-container"),
        runtimeBuilderImageID: temporary.appending("runtime-builder-image-id"),
        linuxTargets: linuxTargets,
        sysrootPreparer: root.appending("swift-sdk/prepare-linux-sysroot.sh"),
        candidate: temporary.appending("candidate"),
        generation: temporary.appending("generation"),
        active: temporary.appending("current"),
        ndkRoot: temporary.appending("ndk"),
        validationFixture: root.appending(
            "collider/engine/Sources/ColliderRuntime/Resources/ToolchainValidationFixtures/AndroidSDKConsumer"
        ),
        validator: root.appending(
            "swift-sdk/validate-target-sdk-artifacts.sh"),
        swiftExecutable: FilePath("/usr/bin/swift"),
        sdkDiscoveryRoot: temporary.appending("swift-sdks"),
        displacedRoot: temporary.appending("displaced"),
        rebuildLock: temporary.appending("rebuild.lock"),
        environment: [:])

    let result = try SwiftTargetSDKColliderRecipe.generation(configuration)

    #expect(result.selected.count == 2)
    #expect(
        result.tasks.filter { $0.id.rawValue.hasPrefix("swift-sdk.download-") }.count
            == 2 + inputs.linuxTargets.flatMap(\.allUbuntuPackages).count)
    #expect(
        !result.tasks.contains { $0.id.rawValue == "swift-sdk.download-linux-target" })
    let ubuntuDownloads = result.tasks.filter { task in
        guard task.id.rawValue.hasPrefix("swift-sdk.download-ubuntu-"),
            case .action(let action) = task.operation
        else { return false }
        return action.kind == "swift-sdk.download-input"
    }
    #expect(ubuntuDownloads.count == inputs.linuxTargets.flatMap(\.allUbuntuPackages).count)
    #expect(result.tasks.contains { $0.id.rawValue == "swift-sdk.build-sdk-generator" })
    #expect(
        result.tasks.contains { $0.id.rawValue == "swift-sdk.build-linux-arm64-runtime" })
    #expect(
        result.tasks.contains { $0.id.rawValue == "swift-sdk.build-linux-x86_64-runtime" })
    #expect(result.tasks.contains { $0.id.rawValue == "swift-sdk.assemble-target-sdks" })
    #expect(result.tasks.contains { $0.id.rawValue == "swift-sdk.validate-target-sdks" })
    var executions: [OCIExecution] = []
    for task in result.tasks {
        executions += try await ociExecutions(in: task.operation)
    }
    #expect(executions.count == 2)
    #expect(executions.allSatisfy { $0.executionPlatform == .linuxARM64OCI })
    #expect(executions.allSatisfy { $0.resourceLimits == .parallelBuild })
    #expect(Set(executions.map(\.artifactTarget)) == [.linuxARM64, .linuxX86_64])

    for target in linuxTargets {
        let architecture = target.target.architecture
        let sysroot = try #require(
            result.tasks.first {
                $0.id.rawValue
                    == "swift-sdk.prepare-linux-\(architecture.rawValue)-libcxx-sysroot"
            })
        #expect(sysroot.dependencies.count == target.target.runtimeUbuntuPackages.count)
        #expect(
            sysroot.dependencies.allSatisfy {
                $0.rawValue.hasPrefix(
                    "swift-sdk.download-ubuntu-\(architecture.rawValue)-")
            })
        guard case .action(let sysrootAction) = sysroot.operation else {
            Issue.record("sysroot preparation must be a recipe-owned action")
            return
        }
        #expect(
            sysrootAction.kind
                == ActionKind(rawValue: "swift-sdk.prepare-linux-sysroot"))
        #expect(
            sysrootAction.requirements.effects.contains(
                ActionEffect(
                    .readWrite,
                    scope: .output(target.sysroot.removingLastComponent()))))
    }

    let generator = try #require(
        result.tasks.first { $0.id.rawValue == "swift-sdk.build-sdk-generator" })
    guard case .action(let generatorAction) = generator.operation else {
        Issue.record("SDK generator compilation must be a recipe-owned action")
        return
    }
    #expect(
        generatorAction.kind
            == ActionKind(rawValue: "swift-sdk.build-generator"))
    let generatorLock = TaskLock.shared(
        configuration.generatorScratch.appending(".collider.lock"))
    let rebuildLock = TaskLock.shared(configuration.rebuildLock)
    #expect(generator.locks == [generatorLock, rebuildLock])

    let assembly = try #require(
        result.tasks.first { $0.id.rawValue == "swift-sdk.assemble-target-sdks" })
    #expect(assembly.locks == [generatorLock, rebuildLock])
    guard case .action(let assemblyAction) = assembly.operation else {
        Issue.record("SDK assembly must be a recipe-owned action")
        return
    }
    #expect(
        assemblyAction.kind
            == ActionKind(rawValue: "swift-sdk.assemble-target-sdks"))
    for target in linuxTargets {
        #expect(
            assemblyAction.requirements.effects.contains(
                ActionEffect(.read, scope: .input(target.runtimeInstall))))
    }

    let validation = try #require(
        result.tasks.first { $0.id.rawValue == "swift-sdk.validate-target-sdks" })
    guard case .action(let validationAction) = validation.operation else {
        Issue.record("SDK validation must be a recipe-owned action")
        return
    }
    #expect(
        validationAction.kind
            == ActionKind(rawValue: "swift-sdk.validate-target-sdks"))
    #expect(validation.outputs.count == 4)
    #expect(
        validationAction.requirements.effects.contains(
            ActionEffect(
                .readWrite,
                scope: .output(configuration.candidate.appending("validation")))))
}

@Test func checkedInTargetSDKInputsAreComplete() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let inputs = try SwiftTargetSDKInputs.load(
        from: FilePath(
            root.appendingPathComponent(
                "swift-sdk/target-sdk-inputs.json"
            ).path))

    #expect(inputs.androidBundleID.hasSuffix("_android"))
    #expect(inputs.linuxBundleID == "nucleus-swift-6.4-linux")
    #expect(inputs.linuxTargets.map(\.architecture) == [.arm64, .amd64])
    for target in inputs.linuxTargets {
        #expect(target.runtimeUbuntuPackages.count == 16)
        #expect(target.sdkUbuntuPackages.count == 38)
        #expect(target.allUbuntuPackages.allSatisfy { !$0.url.contains("libstdc++") })
        #expect(target.allUbuntuPackages.allSatisfy { !$0.url.contains("libicu") })
        #expect(target.allUbuntuPackages.allSatisfy { !$0.url.contains("libxml2") })
        #expect(target.runtimeUbuntuPackages.contains { $0.url.contains("libc++-18-dev") })
        #expect(target.runtimeUbuntuPackages.contains { $0.url.contains("liblzma5_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libvulkan-dev_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libvulkan1_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libpam0g-dev_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libpam0g_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libdrm-dev_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libdrm2_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libgbm-dev_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libgbm1_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libsystemd-dev_") })
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("libsystemd0_") })
        #expect(
            target.allUbuntuPackages.allSatisfy {
                $0.url.hasSuffix("_\(target.architecture.debianArchitecture).deb")
            })
    }
    #expect(inputs.artifacts.macOSHostPackage.sha256.count == 64)
    #expect(inputs.artifacts.androidSDK.sha256.count == 64)
}

@Test func discoveryPublicationPreservesADisplacedMutableInstallation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-sdk-discovery-publication-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = directory.appendingPathComponent("active")
    let displaced = directory.appendingPathComponent("legacy-active")
    try FileManager.default.createDirectory(
        at: link,
        withIntermediateDirectories: true)
    try Data("legacy".utf8).write(
        to: link.appendingPathComponent("payload"))

    try await ColliderRuntime().execute(
        PublishSwiftSDKDiscoveryAction(
            path: FilePath(link.path),
            target: "/immutable/generation",
            displacedItem: FilePath(displaced.path)))

    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == "/immutable/generation")
    #expect(
        try String(
            contentsOf: displaced.appendingPathComponent("payload"),
            encoding: .utf8) == "legacy")
}

@Test func discoveryPublicationReplacesAnExistingLinkWithoutDisplacement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-sdk-discovery-replacement-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let previous = directory.appendingPathComponent("previous")
    let replacement = directory.appendingPathComponent("replacement")
    let link = directory.appendingPathComponent("active")
    let displaced = directory.appendingPathComponent("displaced")
    for path in [previous, replacement] {
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: true)
    }
    try FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: previous.lastPathComponent)

    try await ColliderRuntime().execute(
        PublishSwiftSDKDiscoveryAction(
            path: FilePath(link.path),
            target: replacement.lastPathComponent,
            displacedItem: FilePath(displaced.path)))

    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == replacement.lastPathComponent)
    #expect(!FileManager.default.fileExists(atPath: displaced.path))
}

private actor OCIExecutionRecorder {
    private var recorded: [OCIExecution] = []

    func append(_ execution: OCIExecution) {
        recorded.append(execution)
    }

    func executions() -> [OCIExecution] {
        recorded
    }
}

private func ociExecutions(
    in operation: TaskOperation
) async throws -> [OCIExecution] {
    let recorder = OCIExecutionRecorder()
    try await executeContainerActions(in: operation, recorder: recorder)
    return await recorder.executions()
}

private func executeContainerActions(
    in operation: TaskOperation,
    recorder: OCIExecutionRecorder
) async throws {
    switch operation {
    case .action(let action):
        guard action.requirements.executionPlatform?.environment == .oci else {
            return
        }
        try await action.execute(
            in: ActionContext(
                files: inertActionFileSystem(),
                cancellation: ActionCancellation {},
                logger: ActionLogger { _ in },
                commands: ActionCommandExecutor { _ in
                    throw ActionContainerExecutorFailure.unavailable
                },
                downloads: ActionDownloader { _, _ in },
                containers: ActionContainerExecutor(
                    prepareImage: { _ in },
                    run: { execution in
                        await recorder.append(execution)
                        return CommandResult(status: 0)
                    })))
    case .runOCI(let execution):
        await recorder.append(execution)
    case .sequence(let operations):
        for operation in operations {
            try await executeContainerActions(
                in: operation,
                recorder: recorder)
        }
    default:
        return
    }
}

private func inertActionFileSystem() -> ActionFileSystem {
    ActionFileSystem(
        metadata: { _ in nil },
        contentsEqual: { _, _ in true },
        createDirectory: { _ in },
        copy: { _, _ in },
        remove: { _ in },
        setPermissions: { _, _ in },
        write: { _, _ in })
}
