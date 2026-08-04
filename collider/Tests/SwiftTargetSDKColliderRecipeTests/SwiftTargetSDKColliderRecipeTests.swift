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
    let ubuntuDownloads = result.tasks.compactMap { task -> DownloadSpec? in
        guard task.id.rawValue.hasPrefix("swift-sdk.download-ubuntu-"),
            case .download(let specification, _) = task.operation
        else { return nil }
        return specification
    }
    #expect(ubuntuDownloads.count == inputs.linuxTargets.flatMap(\.allUbuntuPackages).count)
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
    let rebuildLock = TaskLock.shared(configuration.rebuildLock)
    #expect(generator.locks == [generatorLock, rebuildLock])

    let assembly = try #require(
        result.tasks.first { $0.id.rawValue == "swift-sdk.assemble-target-sdks" })
    let assemblyCommands = commands(assembly.operation)
    #expect(assembly.locks == [generatorLock, rebuildLock])
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

    let validation = try #require(
        result.tasks.first { $0.id.rawValue == "swift-sdk.validate-target-sdks" })
    guard case .sequence(let validationOperations) = validation.operation else {
        Issue.record("SDK validation must be an ordered task sequence")
        return
    }
    let hostToolset = configuration.candidate.appending("validation/host-toolset.json")
    let toolsetWrite = try #require(
        validationOperations.first { operation in
            guard case .writeFile(let path, _) = operation else { return false }
            return path == hostToolset
        })
    guard case .writeFile(_, let toolsetBytes) = toolsetWrite else {
        Issue.record("validation toolset must be a file write")
        return
    }
    let toolset = try #require(
        JSONSerialization.jsonObject(with: Data(toolsetBytes)) as? [String: Any])
    let linker = try #require(toolset["linker"] as? [String: String])
    #expect(
        linker["path"]
            == configuration.candidate.appending("toolchain/usr/bin/ld.lld").string)
    let fixtureBuilds = commands(validation.operation).filter {
        $0.arguments.first == "build"
    }
    #expect(fixtureBuilds.count == 4)
    #expect(
        fixtureBuilds.allSatisfy {
            $0.arguments.suffix(2) == ["--toolset", hostToolset.string]
        })
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
