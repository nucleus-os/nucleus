import ColliderCore
import SwiftPlatformColliderRecipe
import SystemPackage
import Testing

@Test func androidFoundationGraphPreservesTheNativeDependencyOrder() throws {
    let taskSet = try SwiftPlatformColliderRecipe.androidFoundationDependencies(
        SwiftAndroidFoundationConfiguration(
            downloadCache: FilePath("/cache"),
            androidInstallRoot: FilePath("/generation/android"),
            ndkRoot: FilePath("/ndk"),
            architectures: ["aarch64"],
            apiLevel: 24,
            jobs: 8,
            environment: ["PATH": "/usr/bin:/bin"]))
    let ordered = try TaskGraph(taskSet.tasks).orderedTasks(
        selecting: taskSet.selected).map(\.id.rawValue)
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
        environment: ["PATH": "/usr/bin:/bin"])
    let taskSet = try SwiftPlatformColliderRecipe.generation(
        SwiftPlatformGenerationConfiguration(
            foundation: foundation,
            candidate: FilePath("/platform/candidate"),
            generation: FilePath("/platform/generations/run"),
            active: FilePath("/platform/current"),
            recipeRoot: FilePath("/workspace/swift-toolchain"),
            sourceWorkspace: FilePath("/source"),
            sourceID: "test",
            sourceRef: "release/6.4.x",
            sourceScheme: "release/6.4.x",
            checkoutMode: .branch,
            hostCC: FilePath("/usr/bin/clang"),
            hostCXX: FilePath("/usr/bin/clang++"),
            bundleName: "swift-test_android.artifactbundle",
            validationWorkRoot: FilePath("/runs/test/work"),
            sdkDiscoveryLink: FilePath(
                "/home/.swiftpm/swift-sdks/swift-test_android.artifactbundle"),
            sdkDiscoveryDisplacedItem: FilePath(
                "/home/.swiftpm/swift-sdks/.legacy-swift-test"),
            reconfigureHost: false,
            environment: ["PATH": "/usr/bin:/bin"]))
    let ordered = try TaskGraph(taskSet.tasks).orderedTasks(
        selecting: taskSet.selected).map(\.id.rawValue)
    let tasks = Dictionary(
        uniqueKeysWithValues: taskSet.tasks.map { ($0.id.rawValue, $0) })
    func index(_ id: String) -> Int {
        ordered.firstIndex(of: id)!
    }
    #expect(index("toolchain.source-sync")
        < index("toolchain.source-update"))
    #expect(index("toolchain.source-update")
        < index("toolchain.host-build"))
    #expect(index("toolchain.host-build")
        < index("toolchain.host-assemble"))
    #expect(index("toolchain.host-assemble")
        < index("toolchain.host-validate"))
    #expect(index("toolchain.host-validate")
        < index("toolchain.host-package"))
    #expect(index("toolchain.host-package")
        < index("toolchain.android-backend-aarch64"))
    #expect(index("toolchain.android-backend-aarch64")
        < index("toolchain.android-sdk-build-aarch64"))
    #expect(index("toolchain.android-sdk-build-aarch64")
        < index("toolchain.android-runtime-linkage"))
    #expect(index("toolchain.android-runtime-linkage")
        < index("toolchain.android-sdk-assemble"))
    #expect(index("toolchain.android-sdk-assemble")
        < index("toolchain.android-sdk-wire"))
    #expect(index("toolchain.android-sdk-wire")
        < index("toolchain.android-sdk-test-aarch64"))
    #expect(index("toolchain.android-sdk-test-aarch64")
        < index("toolchain.activate-generation"))
    #expect(index("toolchain.activate-generation")
        < index("toolchain.publish-sdk-discovery"))

    guard case .command(let sourceUpdate)? =
        tasks["toolchain.source-update"]?.operation
    else {
        Issue.record("toolchain.source-update must be a command")
        return
    }
    #expect(sourceUpdate.arguments.contains("--partial-clone"))
    #expect(sourceUpdate.arguments.contains("--skip-history"))
    #expect(sourceUpdate.arguments.contains("--skip-tags"))

    let upstreamArchive = FilePath(
        "/source/.nucleus-upstream-toolchain.tar.gz")
    let installedDriver = FilePath(
        "/platform/candidate/toolchain/usr/bin/swift-driver")
    #expect(tasks["toolchain.host-build"]?.outputs == [
        OutputDeclaration(
            path: upstreamArchive,
            validation: .regularFile),
    ])
    #expect(tasks["toolchain.host-assemble"]?.inputs.contains(
        .dependencyOutput(upstreamArchive)) == true)
    #expect(tasks["toolchain.host-assemble"]?.outputs == [
        OutputDeclaration(
            path: installedDriver,
            validation: .executableFile),
    ])
    #expect(tasks["toolchain.host-validate"]?.inputs.contains(
        .dependencyOutput(installedDriver)) == true)
    #expect(tasks["toolchain.android-sdk-build-aarch64"]?.inputs.contains(
        .dependencyOutput(installedDriver)) == true)
    #expect(tasks["toolchain.android-sdk-test-aarch64"]?.inputs.contains(
        .dependencyOutput(installedDriver)) == true)
    if case .command(let androidBuild) =
        tasks["toolchain.android-sdk-build-aarch64"]?.operation
    {
        #if os(macOS)
        let ndkBin = "/ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin"
        #else
        let ndkBin = "/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
        #endif
        #expect(androidBuild.environment["CC"]
            == "\(ndkBin)/clang")
        #expect(androidBuild.environment["CXX"]
            == "\(ndkBin)/clang++")
        #expect(androidBuild.environment["CCACHE_PATH"]?
            .hasPrefix("\(ndkBin):") == true)
        #expect(androidBuild.arguments.contains("--skip-clean-libdispatch"))
        #expect(androidBuild.arguments.contains("--skip-clean-foundation"))
        #expect(androidBuild.arguments.contains("--skip-clean-xctest"))
    } else {
        Issue.record("Android SDK build is not a command task")
    }
    for (id, task) in tasks
    where id != "toolchain.activate-generation"
        && id != "toolchain.publish-sdk-discovery"
    {
        #expect(
            task.cachePolicy == .contentAddressed,
            "toolchain work must be resumable: \(id)")
    }
}
