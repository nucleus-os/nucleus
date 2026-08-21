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

@Test func swiftBuildContextKeepsJobCountOutsideArtifactIdentity() {
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
    #expect(narrowerContext.maximumParallelism == 4)
    #expect(defaultContext.identityBytes == narrowerContext.identityBytes)
}

@Test func swiftBuildContextIncludesBuildSystemInArtifactIdentity() {
    let swiftBuild = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .release,
        target: .triple("x86_64-unknown-linux-gnu"),
        toolchainIdentity: "swiftc@fixture")
    let native = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        buildSystem: .native,
        configuration: .release,
        target: .triple("x86_64-unknown-linux-gnu"),
        toolchainIdentity: "swiftc@fixture")

    #expect(swiftBuild.identityBytes != native.identityBytes)
}

@Test func swiftBuildContextIncludesDebugInformationFormatInArtifactIdentity() {
    let inherited = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .release,
        target: .host(identity: "aarch64-linux"),
        toolchainIdentity: "swiftc@fixture")
    let none = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .release,
        debugInformationFormat: SwiftDebugInformationFormat.none,
        target: .host(identity: "aarch64-linux"),
        toolchainIdentity: "swiftc@fixture")

    #expect(inherited.identityBytes != none.identityBytes)
}

@Test func swiftPMInvocationOwnsArgumentsOutputAndSharedLock() {
    let context = SwiftBuildContext(
        packageRoot: fixturePackageRoot,
        configuration: .release,
        debugInformationFormat: SwiftDebugInformationFormat.none,
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
            "--build-system", "swiftbuild",
            "--configuration", "release",
            "--jobs", "10",
            "--scratch-path", scratch.string,
            "--package-path", fixturePackageRoot.string,
            "-debug-info-format", "none",
            "--triple", "aarch64-unknown-linux-gnu",
            "--sanitize", "address",
            "--traits", "diagnostics,renderer",
            "-Xswiftc", "-enable-a",
            "-Xcc", "-DC_FEATURE",
            "-Xcxx", "-DCXX_FEATURE",
            "-Xlinker", "-lfixture",
        ])
    #expect(command.executable == .path(FilePath("/toolchain/bin/swift")))
    #expect(command.environment == ["PATH": "/toolchain/bin"])
    #expect(
        invocation.postcondition
            == PathPostcondition(
                path: scratch.appending(".collider/products"),
                validation: .nonEmptyDirectory))
    #expect(
        invocation.lock
            == .shared(
                scratch.appending(".collider.lock")))
    #expect(
        invocation.productsDirectory
            == scratch.appending(".collider/products"))
    #expect(
        invocation.executable("Fixture")
            == scratch.appending(".collider/products/Fixture"))
    #expect(
        invocation.identityInput
            == .swiftBuildContext(context))

    #expect(
        invocation.commandArguments(
            ["run", "FixtureProbe", "loader"])
            == [
                "run",
                "--build-system", "swiftbuild",
                "--configuration", "release",
                "--jobs", "10",
                "--scratch-path", scratch.string,
                "--package-path", fixturePackageRoot.string,
                "-debug-info-format", "none",
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
            toolsets: [FilePath("/workspace/linux-toolset.json")],
            staticSwiftStandardLibrary: true),
        scratchPath: FilePath("/workspace/.nucleus/swiftpm/android"))

    #expect(
        invocation.commandArguments(["build"]) == [
            "build",
            "--build-system", "swiftbuild",
            "--configuration", "release",
            "--jobs", "10",
            "--scratch-path", "/workspace/.nucleus/swiftpm/android",
            "--package-path", fixturePackageRoot.string,
            "--swift-sdk", "swift-release-6.4.x_android",
            "--triple", "aarch64-unknown-linux-android24",
            "--toolset", "/workspace/linux-toolset.json",
            "--static-swift-stdlib",
        ])
    #expect(
        invocation.productsDirectory
            == FilePath("/workspace/.nucleus/swiftpm/android/.collider/products"))
}

@Test func swiftSDKTargetTripleSelectsDistinctContextIdentity() {
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
    #expect(arm64Invocation.productsDirectory == scratch.appending(".collider/products"))
    #expect(amd64Invocation.productsDirectory == scratch.appending(".collider/products"))
}

@Test func hostProductsUseColliderOwnedPathsAndDeclaredSourceInputs() {
    let scratch = FilePath("/workspace/.nucleus/swiftpm/host")
    let invocation = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: fixturePackageRoot,
            configuration: .debug,
            target: .host(identity: "arm64-macos"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: scratch)

    #expect(
        invocation.productsDirectory
            == scratch.appending(".collider/products"))
    #expect(
        invocation.executable("Fixture")
            == scratch.appending(".collider/products/Fixture"))
    let expectedSourceInputs: [ArtifactInput] = [
        .file(fixturePackageRoot.appending("Package.swift")),
        .sourceCheckout(fixturePackageRoot),
    ]
    #expect(
        invocation.product(
            package: "fixture",
            product: "Fixture",
            packageRoot: fixturePackageRoot,
            environment: [:]
        ).inputs == expectedSourceInputs)
    #expect(
        invocation.testProduct(
            package: "fixture",
            testProduct: "FixtureTests",
            packageRoot: fixturePackageRoot,
            environment: [:]
        ).inputs == expectedSourceInputs)
}

@Test func swiftPMOCIExecutionKeepsGuestArchitectureSeparateFromArtifactArchitecture() throws {
    let imageID = FilePath("/cache/nucleus-linux-build/image-id")
    var producer = TaskBuilder(
        id: TaskID(rawValue: "native.builder"),
        component: ComponentID(rawValue: "native"))
    let image: ArtifactReference = try producer.output(
        "image-id",
        path: imageID,
        validation: .regularFile)
    let overlayRoot = FilePath("/cache/nucleus-linux-build/swiftpm-overlay")
    var overlayProducer = TaskBuilder(
        id: TaskID(rawValue: "native.swiftpm-overlay-artifact"),
        component: ComponentID(rawValue: "native"))
    let overlay: ArtifactReference = try overlayProducer.output(
        "root",
        path: overlayRoot,
        validation: .nonEmptyDirectory)
    let buildWorkspace = PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "fixture-swiftpm",
            artifactTarget: .linuxX86_64,
            role: "build"),
        capacityBytes: 100 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB)
    let compilerCacheWorkspace = PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "fixture-swiftpm-ccache",
            artifactTarget: .linuxX86_64,
            role: "compiler-cache"),
        capacityBytes: 50 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB)
    let execution = SwiftPMOCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxX86_64,
        image: image,
        inputArtifacts: [overlay],
        hostname: "nucleus-linux-amd64-test",
        hostWorkingDirectory: fixturePackageRoot,
        mounts: [
            OCIMount(
                source: fixturePackageRoot,
                target: fixturePackageRoot.string,
                access: .readOnly),
            OCIMount(
                source: overlayRoot,
                target: "/swiftpm-overlay",
                access: .readOnly),
        ],
        buildWorkspace: buildWorkspace,
        compilerCacheWorkspace: compilerCacheWorkspace,
        hostDependencyCache: FilePath("/cache/swiftpm"),
        executableRequirements: [
            OCIExecutableRequirement(
                architecture: .x86_64,
                executable: "/opt/swift-x86_64/usr/bin/swift")
        ],
        containerEnvironment: ["HOME": "/home/fixture"],
        environmentProjection: EnvironmentProjection(
            prefixes: ["PROJECT_"],
            excludedNames: ["PROJECT_PRIVATE"]),
        swiftPMExecutable: "/swiftpm-overlay/usr/bin/swift-package-manager")
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
        scratchPath: FilePath("/workspace/.nucleus/swiftpm/linux-amd64"),
        swiftExecutable: .path(
            FilePath("/opt/swift-x86_64/usr/bin/swift")))

    #expect(invocation.artifactReferences.map(\.path) == [imageID, overlayRoot])
    let logicalTest = TaskBuilder(
        id: TaskID(rawValue: "fixture.test"),
        component: ComponentID(rawValue: "fixture")
    ).build(swiftTests: [
        invocation.testProduct(
            package: "fixture",
            testProduct: "FixtureTests",
            packageRoot: fixturePackageRoot,
            environment: [:])
    ])
    #expect(
        logicalTest.dependencies == [
            TaskID(rawValue: "native.builder"),
            TaskID(rawValue: "native.swiftpm-overlay-artifact"),
        ])

    let operation = try invocation.ociExecution(
        arguments: ["test"],
        workingDirectory: fixturePackageRoot,
        environment: [
            "PATH": "/host/bin",
            "PROJECT_MODE": "debug",
            "PROJECT_PRIVATE": "secret",
        ])

    #expect(operation.executionPlatform == .linuxARM64OCI)
    #expect(operation.artifactTarget == .linuxX86_64)
    #expect(
        operation.executableRequirements == [
            OCIExecutableRequirement(
                architecture: .x86_64,
                executable: "/opt/swift-x86_64/usr/bin/swift")
        ])
    #expect(
        operation.command.starts(with: [
            "swiftpm", "taskset", "--cpu-list", "0-9",
            "/swiftpm-overlay/usr/bin/swift-package-manager", "--build-system",
        ]))
    #expect(operation.containerEnvironment["PATH"] == nil)
    #expect(operation.containerEnvironment["PROJECT_MODE"] == "debug")
    #expect(operation.containerEnvironment["PROJECT_PRIVATE"] == nil)
    #expect(operation.containerEnvironment["SWIFTPM_EXEC_NAME"] == "swift-test")
    #expect(invocation.executionScratchPath.string.hasPrefix("/swiftpm-workspace/"))
    #expect(operation.command.contains(invocation.executionScratchPath.string))
    #expect(operation.command.contains("--swift-sdks-path"))
    #expect(operation.command.contains(SwiftPMInvocation.ociSwiftSDKDirectory.string))
    #expect(
        Set(operation.persistentWorkspaceMounts.map(\.target))
            == ["/swiftpm-workspace", "/ccache"])
    #expect(
        Set(operation.persistentWorkspaceMounts.map(\.workspace.identity))
            == [buildWorkspace.identity, compilerCacheWorkspace.identity])
    #expect(
        operation.mounts.contains(
            OCIMount(
                source: invocation.scratchPath,
                target: "/swiftpm-input",
                access: .readOnly)))
    #expect(
        operation.mounts.contains(
            OCIMount(
                boundedExport: invocation.productsDirectory,
                target: "/swiftpm-products")))
    #expect(
        operation.containerEnvironment["NUCLEUS_SWIFTPM_SCRATCH"]
            == invocation.executionScratchPath.string)
    #expect(
        operation.containerEnvironment["NUCLEUS_SWIFTPM_HOST_PRODUCTS"]
            == invocation.productsDirectory.string)
    let product = invocation.product(
        package: "fixture",
        product: "Fixture",
        packageRoot: fixturePackageRoot,
        environment: [:])
    #expect(product.inputs.contains(.file(fixturePackageRoot.appending("Package.swift"))))
    #expect(product.inputs.contains(.sourceCheckout(fixturePackageRoot)))
}

/// Two checkouts of identical source at different absolute locations compile
/// once and share their results.
///
/// The CI checkout and the authoritative checkout are exactly that pair, and so
/// is one checkout before and after it moves. Placement is not a compilation
/// input, so it must not reach the identity that decides reuse, nor the
/// directory names derived from it.
@Test func swiftBuildContextIdentityIgnoresWhereTheCheckoutSits() {
    func context(checkout: FilePath) -> SwiftBuildContext {
        SwiftBuildContext(
            packageRoot: checkout.appending("collider"),
            configuration: .debug,
            target: .host(identity: "aarch64-linux"),
            toolchainIdentity: "swiftc@fixture",
            swiftFlags: [
                "-file-prefix-map",
                "\(checkout.string)=/nucleus-workspace",
            ],
            cFlags: ["-ffile-prefix-map=\(checkout.string)=/nucleus-workspace"],
            toolsets: [checkout.appending("toolsets/linux.json")],
            identityPathMap: IdentityPathMap(roots: [
                IdentityPathRoot(name: "workspace", path: checkout),
                IdentityPathRoot(name: "cache", path: FilePath("/store/cache")),
            ]))
    }

    let authoritative = context(checkout: FilePath("/Library/Nucleus/checkout"))
    let ci = context(checkout: FilePath("/Users/builder/work/nucleus/nucleus"))
    #expect(authoritative.identityBytes == ci.identityBytes)

    // Without a declared root there is nothing to resolve through, so the two
    // locations are genuinely different builds and must not collide.
    func unmapped(checkout: FilePath) -> SwiftBuildContext {
        SwiftBuildContext(
            packageRoot: checkout.appending("collider"),
            configuration: .debug,
            target: .host(identity: "aarch64-linux"),
            toolchainIdentity: "swiftc@fixture")
    }
    #expect(
        unmapped(checkout: FilePath("/Library/Nucleus/checkout")).identityBytes
            != unmapped(checkout: FilePath("/Users/builder/work/nucleus/nucleus"))
            .identityBytes)

    // A real difference still separates them, so canonicalization cannot be
    // hiding inputs that decide reuse. The path here differs outside every
    // declared root, which is a genuinely different toolset rather than the
    // same one seen from another location.
    let foreignToolset = SwiftBuildContext(
        packageRoot: FilePath("/Library/Nucleus/checkout/collider"),
        configuration: .debug,
        target: .host(identity: "aarch64-linux"),
        toolchainIdentity: "swiftc@fixture",
        toolsets: [FilePath("/opt/other/linux.json")],
        identityPathMap: IdentityPathMap(roots: [
            IdentityPathRoot(
                name: "workspace", path: FilePath("/Library/Nucleus/checkout")),
            IdentityPathRoot(name: "cache", path: FilePath("/store/cache")),
        ]))
    #expect(authoritative.identityBytes != foreignToolset.identityBytes)

    // Equality alone would also hold if the checkout path reached both
    // identities verbatim and simply matched, so the placement itself must be
    // absent rather than merely consistent.
    let map = IdentityPathMap(roots: [
        IdentityPathRoot(
            name: "workspace", path: FilePath("/Library/Nucleus/checkout")),
        IdentityPathRoot(name: "cache", path: FilePath("/store/cache")),
    ])
    #expect(!map.containsDeclaredRoot(inEncoded: authoritative.identityBytes))
}
