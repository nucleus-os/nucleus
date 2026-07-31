import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

@Test func buildContainerExecutionEnforcesTheRootlessOfflineBoundary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-build-container-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let output = root.appendingPathComponent("output", isDirectory: true)
    let temporary = root.appendingPathComponent("temporary", isDirectory: true)
    let report = root.appendingPathComponent("podman-arguments")
    let imageID = root.appendingPathComponent("image-id")
    try FileManager.default.createDirectory(
        at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: source, withIntermediateDirectories: true)
    try Data(
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$REPORT\"\n".utf8
    ).write(to: bin.appendingPathComponent("podman"))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: bin.appendingPathComponent("podman").path)
    try Data(("sha256:" + String(repeating: "a", count: 64) + "\n").utf8)
        .write(to: imageID)

    try await ColliderRuntime().runBuildContainer(
        BuildContainerExecution(
            imageID: FilePath(imageID.path),
            hostname: "fixture-builder",
            workingDirectory: "/src",
            hostWorkingDirectory: FilePath(source.path),
            mounts: [
                BuildContainerMount(
                    source: FilePath(source.path),
                    target: "/src",
                    access: .readOnly),
                BuildContainerMount(
                    source: FilePath(output.path),
                    target: "/build",
                    access: .readWrite),
            ],
            temporaryDirectory: FilePath(temporary.path),
            containerEnvironment: ["BUILD_MODE": "fixture"],
            command: ["fixture", "compile"],
            environment: [
                "PATH": bin.path,
                "REPORT": report.path,
            ]),
        stage: TaskID(rawValue: "fixture.build-container"))

    let arguments = try String(contentsOf: report, encoding: .utf8)
        .split(whereSeparator: \.isNewline).map(String.init)
    #expect(arguments.contains("--network=none"))
    #expect(arguments.contains("--userns=keep-id:uid=1000,gid=1000"))
    #expect(arguments.contains("--cap-drop=all"))
    #expect(arguments.contains("--security-opt=no-new-privileges"))
    #expect(arguments.contains("--read-only"))
    #expect(!arguments.contains("--tmpfs=/tmp:rw,nosuid,nodev,size=8g"))
    #expect(arguments.contains("BUILD_MODE=fixture"))
    #expect(arguments.contains("fixture"))
    #expect(arguments.contains("compile"))
    #expect(FileManager.default.fileExists(atPath: output.path))
    #expect(
        arguments.contains {
            $0.contains("src=\(source.path),target=/src,ro=true")
        })
    #expect(
        arguments.contains {
            $0.contains("src=\(output.path),target=/build,rw=true")
        })
    #expect(
        arguments.contains {
            $0.contains("src=\(temporary.path)/")
                && $0.contains("target=/tmp,rw=true")
        })
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .isEmpty)
}

@Test func buildContainerExecutionRejectsDuplicateMountTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-build-container-invalid-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true)
    let imageID = root.appendingPathComponent("image-id")
    try Data(("sha256:" + String(repeating: "b", count: 64) + "\n").utf8)
        .write(to: imageID)

    await #expect(throws: RuntimeFailure.self) {
        try await ColliderRuntime().runBuildContainer(
            BuildContainerExecution(
                imageID: FilePath(imageID.path),
                hostname: "fixture-builder",
                workingDirectory: "/src",
                hostWorkingDirectory: FilePath(root.path),
                mounts: [
                    BuildContainerMount(
                        source: FilePath(root.path),
                        target: "/src",
                        access: .readOnly),
                    BuildContainerMount(
                        source: FilePath(root.path),
                        target: "/src",
                        access: .readOnly),
                ],
                containerEnvironment: [:],
                command: ["fixture"],
                environment: [:]),
            stage: TaskID(rawValue: "fixture.invalid-build-container"))
    }
}
