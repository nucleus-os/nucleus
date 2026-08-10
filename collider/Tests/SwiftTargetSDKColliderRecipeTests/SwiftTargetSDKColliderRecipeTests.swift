import ColliderCore
import ColliderRuntime
import ColliderTesting
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
    defer { try? FileManager.default.removeItem(atPath: temporary.string) }
    let linuxTargets = inputs.linuxTargets.map { target in
        SwiftLinuxTargetBuildConfiguration(
            target: target,
            runtimeBuildWorkspace: PersistentWorkspaceDeclaration(
                identity: PersistentWorkspaceIdentity(
                    key: "swift-target-runtime-intermediates",
                    artifactTarget: target.architecture.artifactTarget,
                    role: "build"),
                capacityBytes: 200 * 1_024 * 1_024 * 1_024,
                filesystem: .ext4,
                journal: .writeback64MiB),
            runtimeCompilerCacheWorkspace: PersistentWorkspaceDeclaration(
                identity: PersistentWorkspaceIdentity(
                    key: "swift-target-runtime-ccache",
                    artifactTarget: target.architecture.artifactTarget,
                    role: "compiler-cache"),
                capacityBytes: 50 * 1_024 * 1_024 * 1_024,
                filesystem: .ext4,
                journal: .writeback64MiB),
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
        pkgConfigDirectory: root.appending("swift-sdk/pkgconfig"),
        candidate: temporary.appending("candidate"),
        generation: temporary.appending("generation"),
        active: temporary.appending("current"),
        ndkRoot: temporary.appending("ndk"),
        validationFixture: root.appending(
            "swift-sdk/validation/AndroidSDKConsumer"),
        validator: root.appending(
            "swift-sdk/validate-target-sdk-artifacts.sh"),
        swiftExecutable: FilePath("/usr/bin/swift"),
        sdkDiscoveryRoot: temporary.appending("swift-sdks"),
        displacedRoot: temporary.appending("displaced"),
        environment: [:])

    let result = try SwiftTargetSDKColliderRecipe.generation(configuration)

    #expect(result.selected.count == 2)
    #expect(result.activeSDK.path == configuration.active.appending("swift-sdks"))
    #expect(
        result.activeSwift.path
            == configuration.active.appending("toolchain/usr/bin/swift"))
    #expect(
        result.tasks.filter { $0.id.rawValue.hasPrefix("swift-sdk.download-") }.count
            == 2 + inputs.linuxTargets.flatMap(\.allUbuntuPackages).count)
    #expect(
        !result.tasks.contains { $0.id.rawValue == "swift-sdk.download-linux-target" })
    let ubuntuDownloads = result.tasks.filter { task in
        guard task.id.rawValue.hasPrefix("swift-sdk.download-ubuntu-"),
            let action = task.action
        else { return false }
        return action.kind == "swift-sdk.download-input"
    }
    #expect(ubuntuDownloads.count == inputs.linuxTargets.flatMap(\.allUbuntuPackages).count)
    #expect(result.tasks.contains { $0.id.rawValue == "swift-sdk.build-sdk-generator" })
    #expect(
        result.tasks.contains { $0.id.rawValue == "swift-sdk.build-linux-arm64-runtime" })
    #expect(
        result.tasks.contains { $0.id.rawValue == "swift-sdk.build-linux-x86_64-runtime" })
    let runtimeTasks = result.tasks.filter {
        $0.id.rawValue.hasPrefix("swift-sdk.build-linux-")
    }
    #expect(
        runtimeTasks.map(\.locks) == [
            [.checkout("swift-linux-arm64-runtime")],
            [.checkout("swift-linux-x86_64-runtime")],
        ])
    #expect(result.tasks.contains { $0.id.rawValue == "swift-sdk.assemble-target-sdks" })
    #expect(result.tasks.contains { $0.id.rawValue == "swift-sdk.validate-target-sdks" })
    #expect(
        result.tasks.filter {
            $0.id.rawValue.hasPrefix("swift-sdk.validate-")
                && $0.id.rawValue.hasSuffix("-consumer")
        }.count == 4)
    var executions: [OCIExecution] = []
    for task in result.tasks {
        executions += try await ociExecutions(in: task.action)
    }
    #expect(executions.count == 2)
    #expect(executions.allSatisfy { $0.executionPlatform == .linuxARM64OCI })
    #expect(executions.allSatisfy { $0.resourceLimits == .parallelBuild })
    #expect(Set(executions.map(\.artifactTarget)) == [.linuxARM64, .linuxX86_64])
    #expect(
        executions.allSatisfy {
            Set($0.persistentWorkspaceMounts.map(\.target)) == ["/build", "/ccache"]
        })
    let runtimeWorkspaceIdentities = executions.map {
        Set($0.persistentWorkspaceMounts.map(\.workspace.identity))
    }
    #expect(runtimeWorkspaceIdentities.count == 2)
    #expect(runtimeWorkspaceIdentities[0].isDisjoint(with: runtimeWorkspaceIdentities[1]))
    for task in runtimeTasks {
        let action = try #require(task.action)
        let execution = try #require(try await ociExecutions(in: action).first)
        #expect(
            Set(action.requirements.persistentWorkspaceEffects.map(\.workspace.identity))
                == Set(execution.persistentWorkspaceMounts.map(\.workspace.identity)))
    }

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
        guard let sysrootAction = sysroot.action else {
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
    guard let generatorAction = generator.action else {
        Issue.record("SDK generator compilation must be a recipe-owned action")
        return
    }
    #expect(
        generatorAction.kind
            == ActionKind(rawValue: "swift-sdk.build-generator"))
    let generatorLock = TaskLock.shared(
        configuration.generatorScratch.appending(".collider.lock"))
    #expect(generator.locks == [generatorLock])

    let assembly = try #require(
        result.tasks.first { $0.id.rawValue == "swift-sdk.assemble-target-sdks" })
    #expect(assembly.locks == [generatorLock])
    guard let assemblyAction = assembly.action else {
        Issue.record("SDK assembly must be a recipe-owned action")
        return
    }
    #expect(
        assemblyAction.kind
            == ActionKind(rawValue: "swift-sdk.assemble-target-sdks"))
    #expect(
        assembly.inputs.contains(
            .sourceCheckout(configuration.pkgConfigDirectory)))
    #expect(
        assemblyAction.requirements.effects.contains(
            ActionEffect(.read, scope: .input(configuration.pkgConfigDirectory))))
    for target in linuxTargets {
        #expect(
            assemblyAction.requirements.effects.contains(
                ActionEffect(.read, scope: .input(target.runtimeInstall))))
    }

    let consumerValidations = result.tasks.filter {
        $0.id.rawValue.hasPrefix("swift-sdk.validate-")
            && $0.id.rawValue.hasSuffix("-consumer")
    }
    #expect(
        Set(consumerValidations.map(\.id.rawValue))
            == Set([
                "swift-sdk.validate-linux-arm64-consumer",
                "swift-sdk.validate-linux-x86_64-consumer",
                "swift-sdk.validate-android-arm64-consumer",
                "swift-sdk.validate-android-amd64-consumer",
            ]))
    for consumer in consumerValidations {
        let action = try #require(consumer.action)
        #expect(
            action.kind
                == ActionKind(rawValue: "swift-sdk.validate-target-sdk-consumer"))
        #expect(consumer.outputs.count == 1)
        #expect(
            !consumer.dependencies.contains {
                $0.rawValue.hasPrefix("swift-sdk.validate-")
                    && $0.rawValue.hasSuffix("-consumer")
            })
    }

    let validation = try #require(
        result.tasks.first { $0.id.rawValue == "swift-sdk.validate-target-sdks" })
    guard let validationAction = validation.action else {
        Issue.record("SDK validation must be a recipe-owned action")
        return
    }
    #expect(
        validationAction.kind
            == ActionKind(rawValue: "swift-sdk.validate-target-sdk-artifacts"))
    #expect(validation.outputs.count == 1)
    #expect(
        validationAction.requirements.effects.contains(
            ActionEffect(
                .write,
                scope: .output(
                    configuration.candidate.appending("validation/.validated")))))
    for consumer in consumerValidations {
        #expect(validation.dependencies.contains(consumer.id))
    }

    let activeSDKRoot = configuration.generation.appending("swift-sdks/fixture")
    let activeSwift = configuration.generation.appending("toolchain/usr/bin/swift")
    try FileManager.default.createDirectory(
        atPath: activeSDKRoot.string,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        atPath: activeSwift.removingLastComponent().string,
        withIntermediateDirectories: true)
    #expect(
        FileManager.default.createFile(
            atPath: activeSDKRoot.appending("info.json").string, contents: Data("{}".utf8)))
    #expect(FileManager.default.createFile(atPath: activeSwift.string, contents: Data()))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: activeSwift.string)
    try FileManager.default.createSymbolicLink(
        atPath: configuration.active.string,
        withDestinationPath: configuration.generation.string)

    let reused = try SwiftTargetSDKColliderRecipe.prepare(configuration)
    #expect(reused.component.tasks.count == 1)
    #expect(reused.component.tasks[0].id.rawValue == "swift-sdk.use-active-generation")
    #expect(reused.activeSDK.path == configuration.active.appending("swift-sdks"))
    #expect(
        reused.activeSwift.path
            == configuration.active.appending("toolchain/usr/bin/swift"))
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
        #expect(target.sdkUbuntuPackages.count == 43)
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
        #expect(target.sdkUbuntuPackages.contains { $0.url.contains("x11proto-dev_") })
        #expect(
            target.allUbuntuPackages.allSatisfy {
                $0.url.hasSuffix("_\(target.architecture.debianArchitecture).deb")
                    || $0.url.hasSuffix("_all.deb")
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

private func ociExecutions(
    in action: AnyColliderAction?
) async throws -> [OCIExecution] {
    try await recordOCIActionExecution(action).ociExecutions
}
