import ColliderCore
import Foundation
import SwiftTargetSDKColliderRecipe
import SystemPackage
import Testing

@Test func targetSDKGenerationUsesOnlyNativeARM64LinuxRuntimeExecution() throws {
    let root = FilePath(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path)
    let lockFile = root.appending("swift-toolchain/target-sdk.lock.json")
    let lock = try SwiftTargetSDKLock.load(from: lockFile)
    let temporary = FilePath(
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path)
    let configuration = SwiftTargetSDKGenerationConfiguration(
        lock: lock,
        lockFile: lockFile,
        downloadRoot: temporary.appending("downloads"),
        generatorSource: root.appending("swift-toolchain/source/swift-sdk-generator"),
        generatorScratch: temporary.appending("generator"),
        sourceWorkspace: root.appending("swift-toolchain/source"),
        sourceID: "fixture-source-id",
        runtimeBuilderContext: root.appending(
            "swift-toolchain/runtime-build-container"),
        runtimeBuilderImageID: temporary.appending("runtime-builder-image-id"),
        runtimeBuildWorkspace: temporary.appending("runtime-build"),
        runtimeCompilerCache: temporary.appending("runtime-ccache"),
        runtimeInstall: temporary.appending("runtime-install"),
        sysrootPreparer: root.appending("swift-toolchain/prepare-linux-sysroot.sh"),
        linuxSysroot: temporary.appending("linux-sysroot"),
        candidate: temporary.appending("candidate"),
        generation: temporary.appending("generation"),
        active: temporary.appending("current"),
        ndkRoot: temporary.appending("ndk"),
        validationFixture: root.appending(
            "collider/engine/Sources/ColliderRuntime/Resources/ToolchainValidationFixtures/AndroidSDKConsumer"
        ),
        validator: root.appending(
            "swift-toolchain/validate-target-sdk-artifacts.sh"),
        swiftExecutable: FilePath("/usr/bin/swift"),
        sdkDiscoveryRoot: temporary.appending("swift-sdks"),
        displacedRoot: temporary.appending("displaced"),
        environment: [:])

    let result = try SwiftTargetSDKColliderRecipe.generation(configuration)

    #expect(result.selected.count == 2)
    #expect(
        result.tasks.filter { $0.id.rawValue.hasPrefix("toolchain.download-") }.count
            == 2 + lock.ubuntuPackages.count)
    #expect(
        !result.tasks.contains { $0.id.rawValue == "toolchain.download-linux-target" })
    let ubuntuDownloads = result.tasks.compactMap { task -> DownloadSpec? in
        guard task.id.rawValue.hasPrefix("toolchain.download-ubuntu-"),
            case .download(let specification, _) = task.operation
        else { return nil }
        return specification
    }
    #expect(ubuntuDownloads.count == lock.ubuntuPackages.count)
    #expect(
        ubuntuDownloads.allSatisfy {
            $0.acceptedMediaTypes.contains("application/vnd.debian.binary-package")
        })
    #expect(result.tasks.contains { $0.id.rawValue == "toolchain.build-sdk-generator" })
    #expect(
        result.tasks.contains { $0.id.rawValue == "toolchain.build-linux-amd64-runtime" })
    #expect(result.tasks.contains { $0.id.rawValue == "toolchain.assemble-target-sdks" })
    #expect(result.tasks.contains { $0.id.rawValue == "toolchain.validate-target-sdks" })
    let executions = result.tasks.flatMap { ociExecutions($0.operation) }
    #expect(executions.count == 1)
    #expect(executions[0].executionPlatform == .linuxARM64OCI)
    #expect(executions[0].artifactTarget == .linuxX86_64)

    let sysroot = try #require(
        result.tasks.first { $0.id.rawValue == "toolchain.prepare-linux-libcxx-sysroot" })
    #expect(sysroot.dependencies.count == lock.ubuntuPackages.count)
    #expect(
        sysroot.dependencies.allSatisfy {
            $0.rawValue.hasPrefix("toolchain.download-ubuntu-")
        })
    guard case .sequence(let sysrootOperations) = sysroot.operation else {
        Issue.record("sysroot preparation must establish its working directory")
        return
    }
    #expect(
        sysrootOperations.first
            == .createDirectory(configuration.linuxSysroot.removingLastComponent()))

    let generator = try #require(
        result.tasks.first { $0.id.rawValue == "toolchain.build-sdk-generator" })
    #expect(
        commands(generator.operation).contains {
            $0.arguments.contains("--disable-automatic-resolution")
        })
    let generatorLock = TaskLock.shared(
        configuration.generatorScratch.appending(".collider.lock"))
    #expect(generator.locks == [generatorLock])

    let assembly = try #require(
        result.tasks.first { $0.id.rawValue == "toolchain.assemble-target-sdks" })
    let assemblyCommands = commands(assembly.operation)
    #expect(assembly.locks == [generatorLock])
    #expect(
        assemblyCommands.contains {
            guard let option = $0.arguments.firstIndex(of: "--target-swift-package-path") else {
                return false
            }
            return $0.arguments.index(after: option) < $0.arguments.endIndex
                && $0.arguments[$0.arguments.index(after: option)]
                    == configuration.runtimeInstall.string
        })
}

@Test func checkedInTargetSDKLockHasExactDestinations() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let lock = try SwiftTargetSDKLock.load(
        from: FilePath(
            root.appendingPathComponent(
                "swift-toolchain/target-sdk.lock.json"
            ).path))

    #expect(lock.androidAPILevel == 24)
    #expect(lock.androidBundleID.hasSuffix("_android"))
    #expect(lock.linuxBundleID == "nucleus-swift-6.4-linux-amd64")
    #expect(lock.ubuntuPackages.count == 15)
    #expect(lock.ubuntuPackages.allSatisfy { !$0.url.contains("libstdc++") })
    #expect(lock.ubuntuPackages.allSatisfy { !$0.url.contains("libicu") })
    #expect(lock.ubuntuPackages.allSatisfy { !$0.url.contains("libxml2") })
    #expect(lock.ubuntuPackages.contains { $0.url.contains("libc++-18-dev") })
    #expect(lock.ubuntuPackages.contains { $0.url.contains("liblzma5_") })
    #expect(lock.inputs.macOSHostPackage.sha256.count == 64)
    #expect(lock.inputs.androidSDK.sha256.count == 64)
}

private func ociExecutions(_ operation: TaskOperation) -> [OCIExecution] {
    switch operation {
    case .runOCI(let execution):
        [execution]
    case .sequence(let operations):
        operations.flatMap(ociExecutions)
    default:
        []
    }
}

private func commands(_ operation: TaskOperation) -> [CommandSpec] {
    switch operation {
    case .command(let command):
        [command]
    case .sequence(let operations):
        operations.flatMap(commands)
    default:
        []
    }
}
