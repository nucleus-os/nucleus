import ChromiumColliderRecipe
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@Test func chromiumSourcePreparationValidatesAndActivatesAnImmutableGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-chromium-source-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    let sourceID = "1234567890abcdef12345678"
    let source = generations.appendingPathComponent(sourceID)
    let chromium = source.appendingPathComponent("chromium/src")
    let cef = chromium.appendingPathComponent("cef")
    let angle = chromium.appendingPathComponent("third_party/angle")
    let skia = chromium.appendingPathComponent("third_party/skia")
    let v8 = chromium.appendingPathComponent("v8")
    let dawn = chromium.appendingPathComponent("third_party/dawn")
    let depot = directory.appendingPathComponent("depot_tools")
    let lockFile = directory.appendingPathComponent("source.lock.json")
    let environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "GIT_AUTHOR_NAME": "Collider Test",
        "GIT_AUTHOR_EMAIL": "collider@example.invalid",
        "GIT_COMMITTER_NAME": "Collider Test",
        "GIT_COMMITTER_EMAIL": "collider@example.invalid",
    ]
    let runtime = ColliderRuntime()
    func git(_ repository: URL) async throws -> (commit: String, tree: String) {
        try FileManager.default.createDirectory(
            at: repository, withIntermediateDirectories: true)
        let marker = repository.appendingPathComponent("marker")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data("source".utf8).write(to: marker)
        }
        for arguments in [
            ["init", "-q"],
            ["add", "."],
            ["commit", "-qm", "fixture"],
        ] {
            let result = try await runtime.execute(
                CommandSpec(
                    executable: .named("git"),
                    arguments: arguments,
                    workingDirectory: FilePath(repository.path),
                    environment: environment))
            #expect(result.status == 0)
        }
        let commitResult = try await runtime.execute(
            CommandSpec(
                executable: .named("git"),
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: FilePath(repository.path),
                environment: environment,
                output: .captured(limit: 4_096)))
        let treeResult = try await runtime.execute(
            CommandSpec(
                executable: .named("git"),
                arguments: ["rev-parse", "HEAD^{tree}"],
                workingDirectory: FilePath(repository.path),
                environment: environment,
                output: .captured(limit: 4_096)))
        #expect(commitResult.status == 0)
        #expect(treeResult.status == 0)
        return (
            commitResult.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines),
            treeResult.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
        )
    }
    let cefRevision = try await git(cef)
    let angleRevision = try await git(angle)
    let skiaRevision = try await git(skia)
    let dawnRevision = try await git(dawn)
    let pgoName = "fixture.profdata"
    let pgo = chromium.appendingPathComponent(
        "chrome/build/pgo_profiles/\(pgoName)")
    let pgoDescriptor = chromium.appendingPathComponent(
        "chrome/build/linux.pgo.txt")
    let v8PGO = v8.appendingPathComponent(
        "tools/builtins-pgo/profiles/x64.profile")
    for file in [pgo, pgoDescriptor, v8PGO] {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }
    try Data("profile".utf8).write(to: pgo)
    try Data("\(pgoName)\n".utf8).write(to: pgoDescriptor)
    try Data("v8 profile".utf8).write(to: v8PGO)
    let v8Revision = try await git(v8)
    let deps = chromium.appendingPathComponent("DEPS")
    try Data("deps fixture".utf8).write(to: deps)
    let chromiumRevision = try await git(chromium)
    let depotRevision = try await git(depot)
    let graph = source.appendingPathComponent("chromium/.gclient_entries")
    try Data("graph fixture".utf8).write(to: graph)
    let repositories = [
        ("chromium", "chromium/src", chromiumRevision),
        ("cef", "chromium/src/cef", cefRevision),
        ("angle", "chromium/src/third_party/angle", angleRevision),
        ("skia", "chromium/src/third_party/skia", skiaRevision),
        ("v8", "chromium/src/v8", v8Revision),
        ("dawn", "chromium/src/third_party/dawn", dawnRevision),
    ].map { name, checkoutPath, revision in
        ChromiumSourceRepository(
            name: name,
            checkoutPath: checkoutPath,
            remote: "https://example.invalid/\(name).git",
            upstreamRemote: "https://upstream.example.invalid/\(name).git",
            upstreamCommit: revision.commit,
            commit: revision.commit,
            tree: revision.tree)
    }
    let sourceLock = ChromiumSourceLock(
        cefBranch: "fixture",
        chromiumVersion: "1.2.3.4",
        repositories: repositories,
        depotTools: ChromiumDepotToolsLock(
            remote: "https://example.invalid/depot_tools.git",
            commit: depotRevision.commit))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(sourceLock).write(to: lockFile)
    let manifest: [String: Any] = [
        "sourceID": sourceID,
        "sourceLockSHA256": try ArtifactHasher.digest(
            file: FilePath(lockFile.path)
        ).description,
        "repositories": repositories.map {
            ["name": $0.name, "commit": $0.commit, "tree": $0.tree]
        },
        "depotToolsCommit": depotRevision.commit,
        "chromiumDEPSSHA256": try ArtifactHasher.digest(
            file: FilePath(deps.path)
        ).description,
        "gclientGraphSHA256": try ArtifactHasher.digest(
            file: FilePath(graph.path)
        ).description,
        "pgo": [
            "name": pgoName,
            "sha256": try ArtifactHasher.digest(
                file: FilePath(pgo.path)
            ).description,
        ],
        "v8BuiltinsPGO": [
            "name": "x64.profile",
            "sha256": try ArtifactHasher.digest(
                file: FilePath(v8PGO.path)
            ).description,
        ],
    ]
    try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.sortedKeys]
    ).write(
        to: source.appendingPathComponent(
            "source-provenance.json"))
    let current = generations.appendingPathComponent("current")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.prepare-chromium-source"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(
                    source.appendingPathComponent(
                        "source-provenance.json"
                    ).path),
                validation: .json)
        ],
        assessmentPolicy: .always,
        operation: .action(
            try AnyColliderAction(
                PrepareChromiumSourceAction(
                    preparation: ChromiumSourcePreparation(
                        sourceID: sourceID,
                        sourceRoot: FilePath(source.path),
                        sourceGenerations: FilePath(generations.path),
                        current: FilePath(current.path),
                        depotTools: FilePath(depot.path),
                        sourceLockFile: FilePath(lockFile.path),
                        sourceLock: sourceLock,
                        environment: environment)))))
    _ = try await runtime.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: current.path) == sourceID)
}
