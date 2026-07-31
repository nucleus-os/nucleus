import ColliderCore
import Foundation
import SwiftPlatformColliderRecipe
import SystemPackage
import Testing

private let testBuilder = SwiftBuildContainerConfiguration(
    imageID: FilePath("/cache/build-containers/swift/image-id"),
    sourceWorkspace: FilePath("/source"),
    recipeRoot: FilePath("/workspace/swift-toolchain"),
    buildWorkspace: FilePath("/platform/candidate/toolchain-build"),
    compilerCache: FilePath("/cache/ccache/swift"),
    candidate: FilePath("/platform/candidate"))

@Test func androidFoundationGraphPreservesTheNativeDependencyOrder() throws {
    let taskSet = try SwiftPlatformColliderRecipe.androidFoundationDependencies(
        SwiftAndroidFoundationConfiguration(
            downloadCache: FilePath("/cache"),
            androidInstallRoot: FilePath("/generation/android"),
            ndkRoot: FilePath("/ndk"),
            architectures: ["aarch64"],
            apiLevel: 24,
            jobs: 8,
            builder: testBuilder,
            environment: ["PATH": "/usr/bin:/bin"]))
    let ordered = try TaskGraph(taskSet.tasks).orderedTasks(
        selecting: taskSet.selected
    ).map(\.id.rawValue)
    let zlib = ordered.firstIndex(
        of: "toolchain.android-foundation-aarch64-zlib")!
    let openssl = ordered.firstIndex(
        of: "toolchain.android-foundation-aarch64-openssl")!
    let curl = ordered.firstIndex(
        of: "toolchain.android-foundation-aarch64-libcurl")!
    let sanitize = ordered.firstIndex(
        of: "toolchain.android-foundation-aarch64-sanitize")!
    #expect(zlib < openssl)
    #expect(openssl < curl)
    #expect(curl < sanitize)
}

@Test func linuxAndroidFoundationCompilationUsesOnlyTheSwiftBuilder() throws {
    #if !os(macOS)
    let taskSet = try SwiftPlatformColliderRecipe.androidFoundationDependencies(
        SwiftAndroidFoundationConfiguration(
            downloadCache: FilePath("/cache"),
            androidInstallRoot: FilePath("/platform/candidate/android"),
            ndkRoot: FilePath("/ndk"),
            architectures: ["aarch64"],
            apiLevel: 24,
            jobs: 8,
            builder: testBuilder,
            environment: ["PATH": "/usr/bin:/bin"]))
    let compilationTasks = taskSet.tasks.filter {
        $0.id.rawValue.hasPrefix("toolchain.android-foundation-aarch64-")
            && !$0.id.rawValue.contains("-extract-")
            && !$0.id.rawValue.hasSuffix("-sanitize")
    }
    #expect(compilationTasks.count == 7)
    for task in compilationTasks {
        guard case .sequence(let operations) = task.operation else {
            Issue.record("dependency compilation must be an ordered sequence")
            continue
        }
        let buildOperations = operations.dropFirst(2)
        #expect(!buildOperations.isEmpty)
        #expect(buildOperations.allSatisfy(isContainerizedDependencyOperation))
    }
    #endif
}

private func isContainerizedDependencyOperation(
    _ operation: TaskOperation
) -> Bool {
    switch operation {
    case .createDirectory:
        true
    case .runBuildContainer(let execution):
        execution.imageID == testBuilder.imageID
            && execution.command.first == "dependency"
            && execution.workingDirectory.hasPrefix("/candidate/")
            && execution.mounts.contains(
                BuildContainerMount(
                    source: testBuilder.sourceWorkspace,
                    target: "/src",
                    access: .readOnly))
            && execution.mounts.contains(
                BuildContainerMount(
                    source: testBuilder.compilerCache,
                    target: "/ccache",
                    access: .readWrite))
    case .sequence(let operations):
        operations.allSatisfy(isContainerizedDependencyOperation)
    default:
        false
    }
}

@Test func androidFoundationGraphRejectsUnknownArchitectures() {
    #expect(throws: SwiftPlatformRecipeFailure.self) {
        try SwiftPlatformColliderRecipe.androidFoundationDependencies(
            SwiftAndroidFoundationConfiguration(
                downloadCache: FilePath("/cache"),
                androidInstallRoot: FilePath("/generation/android"),
                ndkRoot: FilePath("/ndk"),
                architectures: ["mips"],
                apiLevel: 24,
                jobs: 8,
                builder: testBuilder,
                environment: [:]))
    }
}

@Test func platformGenerationPublishesOnlyAfterAndroidValidation() throws {
    let foundation = SwiftAndroidFoundationConfiguration(
        downloadCache: FilePath("/cache"),
        androidInstallRoot: FilePath("/platform/candidate/android"),
        ndkRoot: FilePath("/ndk"),
        architectures: ["aarch64"],
        apiLevel: 24,
        jobs: 8,
        builder: testBuilder,
        environment: ["PATH": "/usr/bin:/bin"])
    let taskSet = try SwiftPlatformColliderRecipe.generation(
        SwiftPlatformGenerationConfiguration(
            foundation: foundation,
            candidate: FilePath("/platform/candidate"),
            generation: FilePath("/platform/generations/run"),
            active: FilePath("/platform/current"),
            recipeRoot: FilePath("/workspace/swift-toolchain"),
            builderContext: FilePath("/workspace/swift-toolchain/build-container"),
            builderImageID: FilePath("/cache/build-containers/swift/image-id"),
            sourceWorkspace: FilePath("/source"),
            buildWorkspace: FilePath("/platform/candidate/toolchain-build"),
            sourceRepositories: [FilePath("swift")],
            sourceID: "test",
            hostCC: FilePath("/usr/bin/clang"),
            hostCXX: FilePath("/usr/bin/clang++"),
            bundleName: "swift-test_android.artifactbundle",
            validationWorkRoot: FilePath("/runs/test/work"),
            sdkDiscoveryLink: FilePath(
                "/home/.swiftpm/swift-sdks/swift-test_android.artifactbundle"),
            sdkDiscoveryDisplacedItem: FilePath(
                "/home/.swiftpm/swift-sdks/.legacy-swift-test"),
            environment: ["PATH": "/usr/bin:/bin"]))
    let ordered = try TaskGraph(taskSet.tasks).orderedTasks(
        selecting: taskSet.selected
    ).map(\.id.rawValue)
    let tasks = Dictionary(
        uniqueKeysWithValues: taskSet.tasks.map { ($0.id.rawValue, $0) })
    func index(_ id: String) -> Int {
        ordered.firstIndex(of: id)!
    }
    #expect(
        index("toolchain.source-validate")
            < index("toolchain.host-build"))
    #expect(
        index("toolchain.host-build")
            < index("toolchain.host-assemble"))
    #expect(
        index("toolchain.host-assemble")
            < index("toolchain.host-validate"))
    #expect(
        index("toolchain.host-validate")
            < index("toolchain.host-package"))
    #expect(
        index("toolchain.host-package")
            < index("toolchain.android-backend-aarch64"))
    #expect(
        index("toolchain.android-backend-aarch64")
            < index("toolchain.android-sdk-build-aarch64"))
    #expect(
        index("toolchain.android-sdk-build-aarch64")
            < index("toolchain.android-runtime-linkage"))
    #expect(
        index("toolchain.android-runtime-linkage")
            < index("toolchain.android-sdk-assemble"))
    #expect(
        index("toolchain.android-sdk-assemble")
            < index("toolchain.android-sdk-wire"))
    #expect(
        index("toolchain.android-sdk-wire")
            < index("toolchain.android-sdk-test-aarch64"))
    #expect(
        index("toolchain.android-sdk-test-aarch64")
            < index("toolchain.activate-generation"))
    #expect(
        index("toolchain.activate-generation")
            < index("toolchain.publish-sdk-discovery"))

    guard
        case .validateSwiftSourceWorkspace(let sourceValidation)? =
            tasks["toolchain.source-validate"]?.operation
    else {
        Issue.record("toolchain source must be validated in place")
        return
    }
    #expect(sourceValidation.workspaceRoot == FilePath("/source"))
    #expect(sourceValidation.repositories == [FilePath("swift")])

    let upstreamArchive = FilePath(
        "/platform/candidate/toolchain-build/.nucleus-upstream-toolchain.tar.gz")
    let installedDriver = FilePath(
        "/platform/candidate/toolchain/usr/bin/swift-driver")
    #expect(
        tasks["toolchain.host-build"]?.outputs == [
            OutputDeclaration(
                path: upstreamArchive,
                validation: .regularFile)
        ])
    #expect(
        tasks["toolchain.host-assemble"]?.inputs.contains(
            .dependencyOutput(upstreamArchive)) == true)
    #expect(
        tasks["toolchain.host-assemble"]?.outputs == [
            OutputDeclaration(
                path: installedDriver,
                validation: .executableFile)
        ])
    #expect(
        tasks["toolchain.host-validate"]?.inputs.contains(
            .dependencyOutput(installedDriver)) == true)
    #expect(
        tasks["toolchain.android-sdk-build-aarch64"]?.inputs.contains(
            .dependencyOutput(installedDriver)) == true)
    #expect(
        tasks["toolchain.android-sdk-test-aarch64"]?.inputs.contains(
            .dependencyOutput(installedDriver)) == true)
    #if os(macOS)
    if case .command(let androidBuild) =
        tasks["toolchain.android-sdk-build-aarch64"]?.operation
    {
        let ndkBin = "/ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin"
        #expect(androidBuild.environment["CC"] == "\(ndkBin)/clang")
        #expect(androidBuild.environment["CXX"] == "\(ndkBin)/clang++")
    } else {
        Issue.record("macOS Android SDK build is not a native command task")
    }
    #else
    guard
        case .runBuildContainer(let hostBuild)? =
            tasks["toolchain.host-build"]?.operation,
        case .runBuildContainer(let androidBuild)? =
            tasks["toolchain.android-sdk-build-aarch64"]?.operation
    else {
        Issue.record("Linux Swift builds must use the builder container")
        return
    }
    #expect(hostBuild.imageID == FilePath("/cache/build-containers/swift/image-id"))
    #expect(hostBuild.command.prefix(2) == ["host", "python3"])
    #expect(androidBuild.command.prefix(2) == ["android", "python3"])
    #expect(hostBuild.containerEnvironment["CCACHE_DIR"] == "/ccache")
    #expect(hostBuild.containerEnvironment["SWIFTC"] == nil)
    #expect(hostBuild.containerEnvironment["SWIFT_EXEC"] == nil)
    #expect(
        hostBuild.containerEnvironment["LD_LIBRARY_PATH"]?.hasPrefix(
            "/build/.nucleus-candidate-install/usr/lib:"
                + "/build/.nucleus-candidate-install/usr/lib/swift/linux:"
        ) == true)
    #expect(
        hostBuild.containerEnvironment["PATH"]?.contains(
            "/opt/swift-bootstrap/usr/bin") == true)
    #expect(
        hostBuild.containerEnvironment["PATH"]?.contains(
            "/opt/cmake/bin") == true)
    #expect(androidBuild.containerEnvironment["CCACHE_DIR"] == "/ccache")
    #expect(
        androidBuild.containerEnvironment["PATH"]?.contains(
            "/opt/cmake/bin") == true)
    #expect(androidBuild.command.contains("--skip-clean-libdispatch"))
    #expect(androidBuild.command.contains("--skip-clean-foundation"))
    #expect(androidBuild.command.contains("--skip-clean-xctest"))
    #expect(androidBuild.command.contains("--build-subdir=android-aarch64"))
    #expect(!androidBuild.command.contains("--build-subdir=android-aarch64-run"))
    #expect(
        androidBuild.containerEnvironment["ANDROID_NDK_HOME"]
            == "/opt/android-ndk-r30-beta2")
    #expect(
        androidBuild.mounts.contains(
            BuildContainerMount(
                source: FilePath("/source"),
                target: "/src",
                access: .readOnly)))
    #expect(
        hostBuild.mounts.contains(
            BuildContainerMount(
                source: testBuilder.compilerCache,
                target: "/ccache",
                access: .readWrite)))
    #endif
    for (id, task) in tasks
    where id != "toolchain.activate-generation"
        && id != "toolchain.publish-sdk-discovery"
        && id != "toolchain.source-validate"
        && id != "toolchain.host-prepare"
    {
        #expect(
            task.cachePolicy == .contentAddressed,
            "toolchain work must be resumable: \(id)")
    }
    #expect(tasks["toolchain.source-validate"]?.cachePolicy == .always)
    #expect(tasks["toolchain.host-prepare"]?.cachePolicy == .always)
}

private func generationConfiguration(
    sourceWorkspace: FilePath,
    buildWorkspace: FilePath = FilePath("/platform/candidate/toolchain-build"),
    generation: String
) -> SwiftPlatformGenerationConfiguration {
    SwiftPlatformGenerationConfiguration(
        foundation: SwiftAndroidFoundationConfiguration(
            downloadCache: FilePath("/cache"),
            androidInstallRoot: FilePath("/platform/candidate/android"),
            ndkRoot: FilePath("/ndk"),
            architectures: ["aarch64"],
            apiLevel: 24,
            jobs: 8,
            builder: testBuilder,
            environment: [:]),
        candidate: FilePath("/platform/candidate"),
        generation: FilePath("/platform/generations").appending(generation),
        active: FilePath("/platform/current"),
        recipeRoot: FilePath("/workspace/swift-toolchain"),
        builderContext: FilePath("/workspace/swift-toolchain/build-container"),
        builderImageID: FilePath("/cache/build-containers/swift/image-id"),
        sourceWorkspace: sourceWorkspace,
        buildWorkspace: buildWorkspace,
        sourceRepositories: [FilePath("swift")],
        sourceID: "test",
        hostCC: FilePath("/usr/bin/clang"),
        hostCXX: FilePath("/usr/bin/clang++"),
        bundleName: "swift-test_android.artifactbundle",
        validationWorkRoot: FilePath("/runs/test/work"),
        sdkDiscoveryLink: FilePath("/home/.swiftpm/swift-sdks/bundle"),
        sdkDiscoveryDisplacedItem: FilePath("/home/.swiftpm/swift-sdks/.legacy"),
        environment: [:])
}

@Test func obsoleteCrossBuildRootsAreSupersededWithoutDeletingReusableRoots() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-platform-roots-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let build = workspace.appendingPathComponent("build", isDirectory: true)
    let current = "2026-07-28T22-06-32Z-52418"
    let retired = "2026-07-25T20-20-34Z-1147833"
    for name in [
        "android-aarch64",
        "android-x86_64",
        "android-aarch64-\(current)",
        "android-x86_64-\(current)",
        "android-aarch64-\(retired)",
        "android-aarch64-macos-\(retired)",
        // The host build root belongs to no generation and is not a cross build.
        "buildbot_linux",
    ] {
        try FileManager.default.createDirectory(
            at: build.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true)
    }

    let superseded = SwiftPlatformColliderRecipe.supersededAndroidBuildRoots(
        generationConfiguration(
            sourceWorkspace: FilePath("/workspace/swift-toolchain/source"),
            buildWorkspace: FilePath(workspace.path),
            generation: current))

    let names = superseded.map(\.lastComponent?.string)
    #if os(macOS)
    #expect(
        names == [
            "android-aarch64",
            "android-aarch64-\(retired)",
            "android-aarch64-\(current)",
            "android-aarch64-macos-\(retired)",
            "android-x86_64",
            "android-x86_64-\(current)",
        ])
    #else
    #expect(
        names == [
            "android-aarch64-\(retired)",
            "android-aarch64-\(current)",
            "android-aarch64-macos-\(retired)",
            "android-x86_64-\(current)",
        ])
    #endif
}
