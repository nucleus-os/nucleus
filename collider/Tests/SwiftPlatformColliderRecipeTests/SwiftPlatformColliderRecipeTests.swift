import ColliderCore
import Foundation
import SwiftPlatformColliderRecipe
import SystemPackage
import Testing

private let testBuilder = SwiftOCIConfiguration(
    imageID: FilePath("/cache/build-containers/swift/image-reference"),
    sourceWorkspace: FilePath("/source"),
    recipeRoot: FilePath("/workspace/swift-toolchain"),
    buildWorkspace: FilePath(
        "/cache/swift-build-workspaces/linux-arm64-host/workspace"),
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
    let builder = TaskDeclaration(
        id: TaskID(rawValue: "toolchain.swift-builder"),
        component: ComponentID(rawValue: "toolchain"),
        outputs: [
            OutputDeclaration(
                path: testBuilder.imageID,
                validation: .regularFile)
        ],
        operation: .prepareOCIImage(
            OCIImagePreparation(
                executionPlatform: .linuxARM64OCI,
                context: testBuilder.recipeRoot,
                containerFile: testBuilder.recipeRoot.appending("Containerfile"),
                imageID: testBuilder.imageID,
                imageName: "localhost/nucleus-swift-build",
                environment: ["PATH": "/usr/bin:/bin"])))
    let ordered = try TaskGraph([builder] + taskSet.tasks).orderedTasks(
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
}

private func isContainerizedDependencyOperation(
    _ operation: TaskOperation
) -> Bool {
    switch operation {
    case .createDirectory:
        true
    case .runOCI(let execution):
        execution.imageID == testBuilder.imageID
            && execution.command.first == "dependency"
            && execution.workingDirectory.hasPrefix("/candidate/")
            && execution.mounts.contains(
                OCIMount(
                    source: testBuilder.sourceWorkspace,
                    target: "/src",
                    access: .readOnly))
            && execution.mounts.contains(
                OCIMount(
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
            builderImageID: FilePath("/cache/build-containers/swift/image-reference"),
            sourceWorkspace: FilePath("/source"),
            buildWorkspace: FilePath(
                "/cache/swift-build-workspaces/linux-arm64-host/workspace"),
            sourceRepositories: [FilePath("swift")],
            sourceID: "test",
            hostCC: FilePath("/usr/bin/clang"),
            hostCXX: FilePath("/usr/bin/clang++"),
            bundleName: "swift-test_android.artifactbundle",
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
            < index("toolchain.complete-generation"))
    #expect(
        index("toolchain.complete-generation")
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

    guard
        case .prepareHostToolchainBuild(let hostPreparation)? =
            tasks["toolchain.host-prepare"]?.operation
    else {
        Issue.record("host preparation must enforce shared-workspace contracts")
        return
    }
    #expect(
        hostPreparation.stagingRoot
            == FilePath("/platform/candidate/host-staging"))
    #expect(hostPreparation.contracts.map(\.name) == ["host", "Android"])
    #expect(
        hostPreparation.contracts[0].roots.contains(
            FilePath(
                "/cache/swift-build-workspaces/linux-arm64-host/workspace/build/buildbot_linux"
            )))

    let upstreamArchive = FilePath(
        "/platform/candidate/host-upstream-toolchain.tar.gz")
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
    guard
        case .runOCI(let hostBuild)? =
            tasks["toolchain.host-build"]?.operation,
        case .runOCI(let androidBuild)? =
            tasks["toolchain.android-sdk-build-aarch64"]?.operation,
        case .runOCI(let hostValidation)? =
            tasks["toolchain.host-validate"]?.operation,
        case .runOCI(let androidValidation)? =
            tasks["toolchain.android-sdk-test-aarch64"]?.operation
    else {
        Issue.record("Swift generation and validation must use the Linux builder")
        return
    }
    #expect(hostBuild.imageID == FilePath("/cache/build-containers/swift/image-reference"))
    #expect(hostBuild.command.prefix(2) == ["host", "python3"])
    #expect(androidBuild.command.prefix(2) == ["android", "python3"])
    #expect(
        hostValidation.command.prefix(3)
            == [
                "host", "/recipe/build-container/validate-artifacts.sh", "host",
            ])
    #expect(
        androidValidation.command.prefix(3)
            == [
                "android", "/recipe/build-container/validate-artifacts.sh",
                "android-sdk",
            ])
    #expect(hostBuild.containerEnvironment["CCACHE_DIR"] == "/ccache")
    #expect(hostBuild.containerEnvironment["CCACHE_BASEDIR"] == "/")
    #expect(hostBuild.containerEnvironment["CCACHE_COMPILERCHECK"] == "content")
    #expect(hostBuild.containerEnvironment["SWIFTC"] == nil)
    #expect(hostBuild.containerEnvironment["SWIFT_EXEC"] == nil)
    #expect(
        hostBuild.containerEnvironment["LD_LIBRARY_PATH"]?.hasPrefix(
            "/candidate/host-staging/usr/lib:"
                + "/candidate/host-staging/usr/lib/swift/linux:"
        ) == true)
    #expect(
        hostBuild.containerEnvironment["PATH"]?.contains(
            "/opt/swift-bootstrap/usr/bin") == true)
    #expect(
        hostBuild.containerEnvironment["PATH"]?.contains(
            "/opt/cmake/bin") == true)
    #expect(androidBuild.containerEnvironment["CCACHE_DIR"] == "/ccache")
    #expect(androidBuild.containerEnvironment["CCACHE_BASEDIR"] == "/")
    #expect(androidBuild.containerEnvironment["CCACHE_COMPILERCHECK"] == "content")
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
            OCIMount(
                source: FilePath("/source"),
                target: "/src",
                access: .readOnly)))
    #expect(
        hostBuild.mounts.contains(
            OCIMount(
                source: testBuilder.compilerCache,
                target: "/ccache",
                access: .readWrite)))
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
    buildWorkspace: FilePath = FilePath(
        "/cache/swift-build-workspaces/linux-arm64-host/workspace"),
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
        builderImageID: FilePath("/cache/build-containers/swift/image-reference"),
        sourceWorkspace: sourceWorkspace,
        buildWorkspace: buildWorkspace,
        sourceRepositories: [FilePath("swift")],
        sourceID: "test",
        hostCC: FilePath("/usr/bin/clang"),
        hostCXX: FilePath("/usr/bin/clang++"),
        bundleName: "swift-test_android.artifactbundle",
        sdkDiscoveryLink: FilePath("/home/.swiftpm/swift-sdks/bundle"),
        sdkDiscoveryDisplacedItem: FilePath("/home/.swiftpm/swift-sdks/.legacy"),
        environment: [:])
}
