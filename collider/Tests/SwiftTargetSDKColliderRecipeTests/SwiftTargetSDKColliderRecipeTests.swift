import ColliderCore
import Foundation
import SwiftTargetSDKColliderRecipe
import SystemPackage
import Testing

@Test func targetSDKGenerationBuildsBothLinuxArchitecturesOnARM64() throws {
    let root = FilePath(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path)
    let inputsFile = root.appending("swift-toolchain/target-sdk-inputs.json")
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
        generatorSource: root.appending("swift-toolchain/source/swift-sdk-generator"),
        generatorScratch: temporary.appending("generator"),
        sourceWorkspace: root.appending("swift-toolchain/source"),
        sourceID: "fixture-source-id",
        runtimeBuilderContext: root.appending(
            "swift-toolchain/runtime-build-container"),
        runtimeBuilderImageID: temporary.appending("runtime-builder-image-id"),
        linuxTargets: linuxTargets,
        sysrootPreparer: root.appending("swift-toolchain/prepare-linux-sysroot.sh"),
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
        result.tasks.filter { $0.id.rawValue.hasPrefix("swift-sdk.download-") }.count
            == 2 + inputs.linuxTargets.flatMap(\.ubuntuPackages).count)
    #expect(
        !result.tasks.contains { $0.id.rawValue == "swift-sdk.download-linux-target" })
    let ubuntuDownloads = result.tasks.compactMap { task -> DownloadSpec? in
        guard task.id.rawValue.hasPrefix("swift-sdk.download-ubuntu-"),
            case .download(let specification, _) = task.operation
        else { return nil }
        return specification
    }
    #expect(ubuntuDownloads.count == inputs.linuxTargets.flatMap(\.ubuntuPackages).count)
    #expect(
        ubuntuDownloads.allSatisfy {
            $0.acceptedMediaTypes.contains("application/vnd.debian.binary-package")
        })
    #expect(result.tasks.contains { $0.id.rawValue == "swift-sdk.build-sdk-generator" })
    #expect(
        result.tasks.contains { $0.id.rawValue == "swift-sdk.build-linux-arm64-runtime" })
    #expect(
        result.tasks.contains { $0.id.rawValue == "swift-sdk.build-linux-x86_64-runtime" })
    #expect(result.tasks.contains { $0.id.rawValue == "swift-sdk.assemble-target-sdks" })
    #expect(result.tasks.contains { $0.id.rawValue == "swift-sdk.validate-target-sdks" })
    let executions = result.tasks.flatMap { ociExecutions($0.operation) }
    #expect(executions.count == 2)
    #expect(executions.allSatisfy { $0.executionPlatform == .linuxARM64OCI })
    #expect(Set(executions.map(\.artifactTarget)) == [.linuxARM64, .linuxX86_64])

    for target in linuxTargets {
        let architecture = target.target.architecture
        let sysroot = try #require(
            result.tasks.first {
                $0.id.rawValue
                    == "swift-sdk.prepare-linux-\(architecture.rawValue)-libcxx-sysroot"
            })
        #expect(sysroot.dependencies.count == target.target.ubuntuPackages.count)
        #expect(
            sysroot.dependencies.allSatisfy {
                $0.rawValue.hasPrefix(
                    "swift-sdk.download-ubuntu-\(architecture.rawValue)-")
            })
        guard case .sequence(let sysrootOperations) = sysroot.operation else {
            Issue.record("sysroot preparation must establish its working directory")
            return
        }
        #expect(
            sysrootOperations.first
                == .createDirectory(target.sysroot.removingLastComponent()))
    }

    let generator = try #require(
        result.tasks.first { $0.id.rawValue == "swift-sdk.build-sdk-generator" })
    #expect(
        commands(generator.operation).contains {
            $0.arguments.contains("--disable-automatic-resolution")
        })
    let generatorLock = TaskLock.shared(
        configuration.generatorScratch.appending(".collider.lock"))
    #expect(generator.locks == [generatorLock])

    let assembly = try #require(
        result.tasks.first { $0.id.rawValue == "swift-sdk.assemble-target-sdks" })
    let assemblyCommands = commands(assembly.operation)
    #expect(assembly.locks == [generatorLock])
    for target in linuxTargets {
        #expect(
            assemblyCommands.contains {
                guard let option = $0.arguments.firstIndex(of: "--target-swift-package-path")
                else { return false }
                return $0.arguments.index(after: option) < $0.arguments.endIndex
                    && $0.arguments[$0.arguments.index(after: option)]
                        == target.runtimeInstall.string
            })
    }
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
                "swift-toolchain/target-sdk-inputs.json"
            ).path))

    #expect(inputs.androidBundleID.hasSuffix("_android"))
    #expect(inputs.linuxBundleID == "nucleus-swift-6.4-linux")
    #expect(inputs.linuxTargets.map(\.architecture) == [.arm64, .amd64])
    for target in inputs.linuxTargets {
        #expect(target.ubuntuPackages.count == 16)
        #expect(target.ubuntuPackages.allSatisfy { !$0.url.contains("libstdc++") })
        #expect(target.ubuntuPackages.allSatisfy { !$0.url.contains("libicu") })
        #expect(target.ubuntuPackages.allSatisfy { !$0.url.contains("libxml2") })
        #expect(target.ubuntuPackages.contains { $0.url.contains("libc++-18-dev") })
        #expect(target.ubuntuPackages.contains { $0.url.contains("liblzma5_") })
        #expect(
            target.ubuntuPackages.allSatisfy {
                $0.url.hasSuffix("_\(target.architecture.debianArchitecture).deb")
            })
    }
    #expect(inputs.artifacts.macOSHostPackage.sha256.count == 64)
    #expect(inputs.artifacts.androidSDK.sha256.count == 64)
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
