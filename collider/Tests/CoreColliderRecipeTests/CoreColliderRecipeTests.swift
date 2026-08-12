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
