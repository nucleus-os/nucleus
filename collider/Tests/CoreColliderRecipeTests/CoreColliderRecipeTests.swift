import ColliderCore
import ColliderEngine
import ColliderRuntime
import CoreColliderRecipe
import Foundation
import SystemPackage
import Testing

@Test func skiaDependencyParsingIgnoresNestedConditionalURLs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-skia-deps-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    let deps = directory.appendingPathComponent("DEPS")
    try Data(
        """
        deps = {
          "third_party/externals/example": "https://example.com/example.git@1111111111111111111111111111111111111111",
          "conditional": {
            "url": "https://private.example.com/internal.git@2222222222222222222222222222222222222222",
          },
        }
        """.utf8
    ).write(to: deps)

    let dependencies = try CoreColliderRecipe.skiaGitDependencies(
        from: FilePath(deps.path))

    #expect(
        dependencies == [
            SkiaGitDependency(
                relativePath: "third_party/externals/example",
                remote: "https://example.com/example.git",
                commit: "1111111111111111111111111111111111111111")
        ])
}

@Test func exactSkiaDependencyValidationDoesNotMutateTheCheckout() async throws {
    let fixture = try makeSkiaDependencyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let headLog = fixture.checkout.appendingPathComponent(".git/logs/HEAD")
    let config = fixture.checkout.appendingPathComponent(".git/config")
    let headLogBefore = try Data(contentsOf: headLog)
    let configBefore = try Data(contentsOf: config)

    try await executeSkiaDependencyAction(
        root: fixture.skia,
        dependency: fixture.dependency)

    #expect(try Data(contentsOf: headLog) == headLogBefore)
    #expect(try Data(contentsOf: config) == configBefore)
}

@Test func trackedSkiaChangesFailBeforeRemoteRepair() async throws {
    let fixture = try makeSkiaDependencyFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("modified\n".utf8).write(
        to: fixture.checkout.appendingPathComponent("tracked.txt"))
    let originalRemote = try runGit(
        ["-C", fixture.checkout.path, "remote", "get-url", "origin"])
    let mismatched = SkiaGitDependency(
        relativePath: fixture.dependency.relativePath,
        remote: fixture.root.appendingPathComponent("replacement.git").path,
        commit: fixture.dependency.commit)

    await #expect(throws: (any Error).self) {
        try await executeSkiaDependencyAction(root: fixture.skia, dependency: mismatched)
    }

    #expect(
        try runGit(["-C", fixture.checkout.path, "remote", "get-url", "origin"])
            == originalRemote)
}

@Test func androidHostValidationChecksELFAndKotlinJNIContracts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-android-host-validation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let library = directory.appendingPathComponent("libnucleus-android.so")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: library)

    let kotlin = directory.appendingPathComponent(
        "android/nucleus/src/main/kotlin/dev/nucleus/android/NucleusNative.kt")
    try FileManager.default.createDirectory(
        at: kotlin.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        "object NucleusNative { external fun frame() }\n".utf8
    ).write(to: kotlin)

    let readelf = directory.appendingPathComponent(
        "ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf")
    try FileManager.default.createDirectory(
        at: readelf.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let thunks = (0..<20).map {
        "1: 0 FUNC GLOBAL DEFAULT 1 "
            + "Java_dev_nucleus_android_AndroidHost__thunk\($0)"
    }.joined(separator: "\\n")
    try Data(
        """
        #!/bin/sh
        case "$1" in
          -h) printf '  Machine: AArch64\\n' ;;
          -d) printf 'NEEDED [libandroid.so]\\nNEEDED [libvulkan.so]\\nNEEDED [libSwiftJava.so]\\n' ;;
          -Ws) printf '  FUNC GLOBAL DEFAULT JNI_OnLoad\\n  FUNC LOCAL PROTECTED 1 swift_retain\\n  FUNC GLOBAL DEFAULT Java_dev_nucleus_android_NucleusNative_frame\\n\(thunks)\\n' ;;
        esac
        """.utf8
    ).write(to: readelf)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: readelf.path)

    var producerBuilder = TaskBuilder(
        id: TaskID(rawValue: "core.android-host.build"),
        component: ComponentID(rawValue: "core"))
    let libraryArtifact: ArtifactReference = try producerBuilder.output(
        "android-library",
        path: FilePath(library.path),
        validation: .regularFile)
    let producer = producerBuilder.build()
    let validation = try CoreColliderRecipe.validateAndroidHost(
        root: FilePath(directory.path),
        library: libraryArtifact,
        ndk: FilePath(directory.appendingPathComponent("ndk").path),
        environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ])
    let report = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([producer, validation.task]),
        selected: [validation.task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [producer.id, validation.task.id])
}

private struct SkiaDependencyFixture {
    let root: URL
    let skia: URL
    let checkout: URL
    let dependency: SkiaGitDependency
}

private func makeSkiaDependencyFixture() throws -> SkiaDependencyFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-skia-fast-path-\(UUID().uuidString)")
    let remote = root.appendingPathComponent("remote")
    let skia = root.appendingPathComponent("skia")
    let checkout = skia.appendingPathComponent("third_party/externals/example")
    try FileManager.default.createDirectory(
        at: remote,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: skia,
        withIntermediateDirectories: true)
    try Data("deps = {}\n".utf8).write(to: skia.appendingPathComponent("DEPS"))
    _ = try runGit(["init", remote.path])
    try Data("tracked\n".utf8).write(to: remote.appendingPathComponent("tracked.txt"))
    _ = try runGit(["-C", remote.path, "add", "tracked.txt"])
    _ = try runGit([
        "-C", remote.path,
        "-c", "user.name=Collider Tests",
        "-c", "user.email=collider@example.invalid",
        "commit", "-m", "fixture",
    ])
    _ = try runGit([
        "-C", remote.path,
        "-c", "user.name=Collider Tests",
        "-c", "user.email=collider@example.invalid",
        "tag", "-a", "fixture", "-m", "fixture",
    ])
    let pinnedObject = try runGit([
        "-C", remote.path, "rev-parse", "refs/tags/fixture",
    ])
    try FileManager.default.createDirectory(
        at: checkout.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    _ = try runGit(["clone", remote.path, checkout.path])
    return SkiaDependencyFixture(
        root: root,
        skia: skia,
        checkout: checkout,
        dependency: SkiaGitDependency(
            relativePath: "third_party/externals/example",
            remote: remote.path,
            commit: pinnedObject))
}

private func executeSkiaDependencyAction(
    root: URL,
    dependency: SkiaGitDependency
) async throws {
    let runtime = ColliderRuntime()
    do {
        _ = try await runtime.execute(
            MaterializeSkiaDependenciesAction(
                skia: FilePath(root.path),
                dependencies: [dependency],
                environment: ProcessInfo.processInfo.environment))
        await runtime.shutdown()
    } catch {
        await runtime.shutdown()
        throw error
    }
}

private func runGit(_ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw CocoaError(
            .fileReadUnknown,
            userInfo: [NSDebugDescriptionErrorKey: String(decoding: bytes, as: UTF8.self)])
    }
    return String(decoding: bytes, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
