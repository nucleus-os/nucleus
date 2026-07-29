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
        scratchPath: scratch)
    let command = invocation.command(
        arguments: ["test"],
        workingDirectory: FilePath("/workspace/core"),
        environment: ["PATH": "/toolchain/bin"])

    #expect(
        command.arguments == [
            "test",
            "--configuration", "release",
            "--scratch-path", scratch.string,
            "--package-path", fixturePackageRoot.string,
            "--triple", "aarch64-unknown-linux-gnu",
            "--sanitize", "address",
            "--traits", "diagnostics,renderer",
            "-Xswiftc", "-enable-a",
            "-Xcc", "-DC_FEATURE",
            "-Xcxx", "-DCXX_FEATURE",
            "-Xlinker", "-lfixture",
        ])
    #expect(command.environment["NUCLEUS_SWIFTPM_SANITIZER"] == "address")
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
            == .value(
                name: "swift-build-context",
                bytes: context.identityBytes))

    #expect(
        invocation.commandArguments(
            ["run", "FixtureProbe", "loader"])
            == [
                "run",
                "--configuration", "release",
                "--scratch-path", scratch.string,
                "--package-path", fixturePackageRoot.string,
                "--triple", "aarch64-unknown-linux-gnu",
                "--sanitize", "address",
                "--traits", "diagnostics,renderer",
                "-Xswiftc", "-enable-a",
                "-Xcc", "-DC_FEATURE",
                "-Xcxx", "-DCXX_FEATURE",
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
            staticSwiftStandardLibrary: true),
        scratchPath: FilePath("/workspace/.nucleus/swiftpm/android"))

    #expect(
        invocation.commandArguments(["build"]) == [
            "build",
            "--configuration", "release",
            "--scratch-path", "/workspace/.nucleus/swiftpm/android",
            "--package-path", fixturePackageRoot.string,
            "--swift-sdk", "swift-release-6.4.x_android",
            "--static-swift-stdlib",
        ])
    #expect(
        invocation.configurationProducts
            == FilePath(
                "/workspace/.nucleus/swiftpm/android/out/Products/"
                    + "Release-android-aarch64"))
}
