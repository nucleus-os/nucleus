import ColliderCore
import SystemPackage
import Testing

private let fixturePackageRoot = FilePath("/workspace")

@Test func swiftBuildContextCanonicalizesTraitsAndPreservesFlagOrder() {
    let first = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@fixture",
        traits: ["renderer", "diagnostics", "renderer"],
        swiftFlags: ["-enable-a", "-enable-b"],
        cFlags: ["-DC_FIRST", "-DC_SECOND"],
        cxxFlags: ["-DCXX_FIRST", "-DCXX_SECOND"])
    let equivalent = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@fixture",
        traits: ["diagnostics", "renderer"],
        swiftFlags: ["-enable-a", "-enable-b"],
        cFlags: ["-DC_FIRST", "-DC_SECOND"],
        cxxFlags: ["-DCXX_FIRST", "-DCXX_SECOND"])
    let reorderedFlags = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@fixture",
        traits: ["diagnostics", "renderer"],
        swiftFlags: ["-enable-b", "-enable-a"],
        cFlags: ["-DC_FIRST", "-DC_SECOND"],
        cxxFlags: ["-DCXX_FIRST", "-DCXX_SECOND"])

    #expect(first == equivalent)
    #expect(first.identityBytes == equivalent.identityBytes)
    #expect(first.identityBytes != reorderedFlags.identityBytes)
}

@Test func swiftBuildContextOwnsMaximumParallelism() {
    let defaultContext = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@fixture")
    let narrowerContext = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .debug,
        target: .host(identity: "x86_64-linux"),
        toolchainIdentity: "swiftc@fixture",
        maximumParallelism: 4)

    #expect(defaultContext.maximumParallelism == 10)
    #expect(defaultContext.identityBytes != narrowerContext.identityBytes)
}

@Test func swiftPMInvocationOwnsArgumentsOutputAndSharedLock() {
    let context = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .release,
        target: .triple("aarch64-unknown-linux-gnu"),
        toolchainIdentity: "swiftc@fixture",
        sanitizer: "address",
        traits: ["diagnostics", "renderer"],
        swiftFlags: ["-enable-a"],
        cFlags: ["-DC_FEATURE"],
        cxxFlags: ["-DCXX_FEATURE"],
        linkerFlags: ["-lfixture"])
    let scratch = FilePath("/workspace/.nucleus/swiftpm/fixture")
    let invocation = SwiftPMInvocation(
        context: context,
        scratchPath: scratch,
        swiftExecutable: .path(FilePath("/toolchain/bin/swift")))
    let command = invocation.command(
        arguments: ["test"],
        workingDirectory: FilePath("/workspace/core"),
        environment: ["PATH": "/toolchain/bin"])

    #expect(
        command.arguments == [
            "test",
            "--configuration", "release",
            "--jobs", "10",
            "--scratch-path", scratch.string,
            "--package-path", fixturePackageRoot.string,
            "--triple", "aarch64-unknown-linux-gnu",
            "--sanitize", "address",
            "--traits", "diagnostics,renderer",
            "-Xswiftc", "-enable-a",
            "-Xcc", "-DC_FEATURE",
            "-Xcxx", "-DCXX_FEATURE",
            "-Xcxx", "-I\(invocation.generatedModuleMaps.string)",
            "-Xlinker", "-lfixture",
        ])
    #expect(command.executable == .path(FilePath("/toolchain/bin/swift")))
    #expect(command.environment == ["PATH": "/toolchain/bin"])
    #expect(
        invocation.postcondition
            == PathPostcondition(
                path: scratch,
                validation: .nonEmptyDirectory))
    #expect(
        invocation.lock
            == .shared(
                scratch.appending(".collider.lock")))
    #expect(
        invocation.productsRoot
            == scratch.appending("out/Products"))
    #expect(
        invocation.configurationProducts
            == scratch.appending("out/Products/Release-linux-aarch64"))
    #expect(
        invocation.generatedModuleMaps
            == scratch.appending(
                "out/Intermediates.noindex/GeneratedModuleMaps-linux-aarch64"))
    #expect(
        invocation.executable("Fixture")
            == scratch.appending(
                "out/Products/Release-linux-aarch64/Fixture"))
    #expect(
        invocation.generatedSwiftHeader("Fixture")
            == scratch.appending(
                "out/Intermediates.noindex/"
                    + "GeneratedModuleMaps-linux-aarch64/Fixture-Swift.h"))
    #expect(
        invocation.identityInput
            == .swiftBuildContext(context))

    #expect(
        invocation.commandArguments(
            ["run", "FixtureProbe", "loader"])
            == [
                "run",
                "--configuration", "release",
                "--jobs", "10",
                "--scratch-path", scratch.string,
                "--package-path", fixturePackageRoot.string,
                "--triple", "aarch64-unknown-linux-gnu",
                "--sanitize", "address",
                "--traits", "diagnostics,renderer",
                "-Xswiftc", "-enable-a",
                "-Xcc", "-DC_FEATURE",
                "-Xcxx", "-DCXX_FEATURE",
                "-Xcxx", "-I\(invocation.generatedModuleMaps.string)",
                "-Xlinker", "-lfixture",
                "FixtureProbe", "loader",
            ])
}

@Test func swiftSDKContextOwnsCrossCompilationArgumentsAndProducts() {
    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: fixturePackageRoot,
            configuration: .release,
            target: .swiftSDK(
                name: "swift-release-6.4.x_android",
                targetTriple: "aarch64-unknown-linux-android24"),
            toolchainIdentity: "swiftc@fixture",
            toolsets: [FilePath("/workspace/linux-toolset.json")],
            staticSwiftStandardLibrary: true),
        scratchPath: FilePath("/workspace/.nucleus/swiftpm/android"))

    #expect(
        invocation.commandArguments(["build"]) == [
            "build",
            "--configuration", "release",
            "--jobs", "10",
            "--scratch-path", "/workspace/.nucleus/swiftpm/android",
            "--package-path", fixturePackageRoot.string,
            "--swift-sdk", "swift-release-6.4.x_android",
            "--triple", "aarch64-unknown-linux-android24",
            "--toolset", "/workspace/linux-toolset.json",
            "--static-swift-stdlib",
            "-Xcxx", "-I\(invocation.generatedModuleMaps.string)",
        ])
    #expect(
        invocation.configurationProducts
            == FilePath(
                "/workspace/.nucleus/swiftpm/android/out/Products/"
                    + "Release-android-aarch64"))
}

@Test func swiftSDKTargetTripleSelectsDistinctContextAndProductIdentity() {
    let arm64 = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .release,
        target: .swiftSDK(
            name: "swift-release-6.4.x_android",
            targetTriple: "aarch64-unknown-linux-android24"),
        toolchainIdentity: "swiftc@fixture")
    let amd64 = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .release,
        target: .swiftSDK(
            name: "swift-release-6.4.x_android",
            targetTriple: "x86_64-unknown-linux-android24"),
        toolchainIdentity: "swiftc@fixture")

    let scratch = FilePath("/workspace/.nucleus/swiftpm/android")
    let arm64Invocation = SwiftPMInvocation(
        context: arm64,
        scratchPath: scratch)
    let amd64Invocation = SwiftPMInvocation(
        context: amd64,
        scratchPath: scratch)

    #expect(arm64.identityBytes != amd64.identityBytes)
    #expect(
        arm64Invocation.configurationProducts
            == scratch.appending("out/Products/Release-android-aarch64"))
    #expect(
        amd64Invocation.configurationProducts
            == scratch.appending("out/Products/Release-android-x86_64"))
}

@Test func hostProductsUseSwiftPMsUnsuffixedXcodeBuildDirectories() {
    let scratch = FilePath("/workspace/.nucleus/swiftpm/host")
    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: fixturePackageRoot,
            configuration: .debug,
            target: .host(identity: "arm64-macos"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: scratch)

    #expect(
        invocation.configurationProducts
            == scratch.appending("out/Products/Debug"))
    #expect(
        invocation.generatedModuleMaps
            == scratch.appending(
                "out/Intermediates.noindex/GeneratedModuleMaps"))
    #expect(
        invocation.executable("Fixture")
            == scratch.appending("out/Products/Debug/Fixture"))
}

@Test func swiftPMOCIExecutionKeepsGuestArchitectureSeparateFromArtifactArchitecture() throws {
    let imageID = FilePath("/cache/nucleus-linux-build/image-id")
    var producer = TaskBuilder(
        id: TaskID(rawValue: "native.builder"),
        component: ComponentID(rawValue: "native"))
    let image: ArtifactReference<FileArtifact> = try producer.output(
        "image-id",
        path: imageID,
        validation: .regularFile)
    let execution = SwiftPMOCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxX86_64,
        image: image,
        hostname: "nucleus-linux-amd64-test",
        hostWorkingDirectory: fixturePackageRoot,
        mounts: [
            OCIMount(
                source: fixturePackageRoot,
                target: fixturePackageRoot.string,
                access: .readWrite)
        ],
        intelBinaryTranslationPolicy: .required,
        containerEnvironment: ["HOME": "/home/nucleus-build"])
    let context = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .debug,
        target: .swiftSDK(
            name: "swift-fixture-linux",
            targetTriple: "x86_64-unknown-linux-gnu"),
        toolchainIdentity: "nucleus-linux-build@fixture",
        execution: .oci(execution))
    let invocation = SwiftPMInvocation(
        context: context,
        scratchPath: FilePath("/workspace/.nucleus/swiftpm/linux-amd64"))

    let operation = try invocation.ociExecution(
        arguments: ["test"],
        workingDirectory: fixturePackageRoot,
        environment: [
            "PATH": "/host/bin",
            "NUCLEUS_NATIVE_SDK_ROOT": "/cache/native-sdk",
        ])

    #expect(operation.executionPlatform == .linuxARM64OCI)
    #expect(operation.artifactTarget == .linuxX86_64)
    #expect(operation.intelBinaryTranslationPolicy == .required)
    #expect(
        operation.command.starts(with: [
            "swiftpm", "taskset", "--cpu-list", "0-9", "swift", "test",
        ]))
    #expect(operation.containerEnvironment["PATH"] == nil)
    #expect(operation.containerEnvironment["NUCLEUS_NATIVE_SDK_ROOT"] == nil)
}
