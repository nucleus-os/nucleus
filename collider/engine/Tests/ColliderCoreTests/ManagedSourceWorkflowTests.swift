import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

@Test func chromiumDepotToolsMaterializesItsDeclaredCommit() async throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-managed-source-\(UUID().uuidString)")
    let remote = fixture.appendingPathComponent("remote")
    let depotCheckout = fixture.appendingPathComponent("depot-tools")
    try FileManager.default.createDirectory(
        at: remote,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }

    _ = try await fixtureGit(
        ["init", "--quiet", "--initial-branch=main"],
        in: remote)
    let marker = remote.appendingPathComponent("marker.txt")
    try Data("first\n".utf8).write(to: marker)
    _ = try await fixtureGit(["add", "marker.txt"], in: remote)
    try await fixtureCommit("first", in: remote)
    let first = try await fixtureGit(["rev-parse", "HEAD"], in: remote)
    try Data("second\n".utf8).write(to: marker)
    _ = try await fixtureGit(["add", "marker.txt"], in: remote)
    try await fixtureCommit("second", in: remote)

    let environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    ]
    let depotTask = TaskDeclaration(
        id: TaskID(rawValue: "fixture.depot-tools"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.value(name: "commit", bytes: Array(first.utf8))],
        outputs: [
            OutputDeclaration(
                path: FilePath(
                    depotCheckout.appendingPathComponent("marker.txt").path),
                validation: .regularFile)
        ],
        operation: .prepareChromiumDepotTools(
            ChromiumDepotToolsPreparation(
                repository: FilePath(depotCheckout.path),
                remote: remote.path,
                commit: first,
                environment: environment)))

    let runtime = ColliderRuntime()
    _ = try await runtime.execute(
        graph: TaskGraph([depotTask]),
        selected: [depotTask.id],
        stateRoot: FilePath(
            fixture.appendingPathComponent("state").path),
        options: TaskExecutionOptions(quiet: true))

    #expect(
        try String(
            contentsOf: depotCheckout.appendingPathComponent("marker.txt"),
            encoding: .utf8) == "first\n")
}

@Test func swiftSourceValidationRequiresRecordedCleanSubmodules() async throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-submodules-\(UUID().uuidString)")
    let remote = fixture.appendingPathComponent("remote")
    let root = fixture.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }

    _ = try await fixtureGit(["init", "--quiet", "--initial-branch=main"], in: remote)
    try Data("source\n".utf8).write(
        to: remote.appendingPathComponent("source.txt"))
    _ = try await fixtureGit(["add", "source.txt"], in: remote)
    try await fixtureCommit("source", in: remote)
    _ = try await fixtureGit(["init", "--quiet", "--initial-branch=main"], in: root)
    _ = try await fixtureGit(
        [
            "-c", "protocol.file.allow=always",
            "submodule", "add", "--quiet", remote.path,
            "swift-toolchain/source/swift",
        ], in: root)
    _ = try await fixtureGit(["add", ".gitmodules", "swift-toolchain/source/swift"], in: root)
    try await fixtureCommit("source graph", in: root)

    let environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    ]
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.swift-source-validate"),
        component: ComponentID(rawValue: "fixture"),
        cachePolicy: .always,
        operation: .validateSwiftSourceWorkspace(
            SwiftSourceWorkspaceValidation(
                workspaceRoot: FilePath(
                    root.appendingPathComponent("swift-toolchain/source").path),
                repositories: [FilePath("swift")],
                environment: environment)))
    let runtime = ColliderRuntime()
    _ = try await runtime.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(fixture.appendingPathComponent("state-clean").path),
        options: TaskExecutionOptions(quiet: true))

    try Data("dirty\n".utf8).write(
        to: root.appendingPathComponent(
            "swift-toolchain/source/swift/source.txt"))
    await #expect(throws: RuntimeFailure.self) {
        _ = try await runtime.execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(fixture.appendingPathComponent("state-dirty").path),
            options: TaskExecutionOptions(quiet: true))
    }
}

private func fixtureCommit(_ message: String, in repository: URL) async throws {
    _ = try await fixtureGit(
        [
            "-c", "user.name=Collider Tests",
            "-c", "user.email=collider@example.invalid",
            "commit", "--quiet", "-m", message,
        ], in: repository)
}

@discardableResult
private func fixtureGit(
    _ arguments: [String],
    in repository: URL
) async throws -> String {
    let result = try await ColliderRuntime().execute(
        CommandSpec(
            executable: .path(FilePath("/usr/bin/git")),
            arguments: ["-C", repository.path] + arguments,
            workingDirectory: FilePath(repository.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin"
            ],
            output: .combined(limit: 1_024 * 1_024)))
    guard result.status == 0 else {
        throw RuntimeFailure.commandFailed(status: result.status)
    }
    return result.standardOutput
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
