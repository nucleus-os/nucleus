import ChromiumColliderRecipe
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@Test func depotToolsMaterializesItsDeclaredCommitAndRejectsTrackedChanges() async throws {
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
        id: TaskID(rawValue: "browser.depot-tools-fixture"),
        component: ComponentID(rawValue: "browser"),
        inputs: [.value(name: "commit", bytes: Array(first.utf8))],
        outputs: [
            OutputDeclaration(
                path: FilePath(depotCheckout.appendingPathComponent("marker.txt").path),
                validation: .regularFile)
        ],
        assessmentPolicy: .always,
        action:
            try AnyColliderAction(
                PrepareChromiumDepotToolsAction(
                    repository: FilePath(depotCheckout.path),
                    remote: remote.path,
                    commit: first,
                    environment: environment)))

    let runtime = ColliderRuntime()
    _ = try await runtime.execute(
        graph: TaskGraph([depotTask]),
        selected: [depotTask.id],
        stateRoot: FilePath(fixture.appendingPathComponent("state").path),
        options: TaskExecutionOptions(quiet: true))
    #expect(
        try String(
            contentsOf: depotCheckout.appendingPathComponent("marker.txt"),
            encoding: .utf8) == "first\n")

    try Data("modified\n".utf8).write(
        to: depotCheckout.appendingPathComponent("marker.txt"))
    await #expect(throws: (any Error).self) {
        try await runtime.execute(
            graph: TaskGraph([depotTask]),
            selected: [depotTask.id],
            stateRoot: FilePath(fixture.appendingPathComponent("state").path),
            options: TaskExecutionOptions(quiet: true))
    }
}

private func fixtureCommit(_ message: String, in repository: URL) async throws {
    _ = try await fixtureGit(
        [
            "-c", "user.name=Collider Tests",
            "-c", "user.email=collider@example.invalid",
            "commit", "--quiet", "-m", message,
        ],
        in: repository)
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
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
}
