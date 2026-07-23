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
}
