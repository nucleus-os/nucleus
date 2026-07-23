import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage
import Testing

@Test func runRegistryPublishesManifestEventsAndLatest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-registry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "doctor"])
    try await registry.record(
        kind: .taskStarted, task: TaskID(rawValue: "doctor.host"), in: run)
    try await registry.appendLog(Array("diagnostic\n".utf8), in: run)
    try await registry.finish(run, status: .succeeded)

    let manifest = try JSONDecoder().decode(
        RunManifest.self,
        from: Data(contentsOf: directory
            .appendingPathComponent("runs/\(run.id.rawValue)/manifest.json")))
    #expect(manifest.status == .succeeded)
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: directory.appendingPathComponent("latest").path)
        == "runs/\(run.id.rawValue)")
    let events = try String(contentsOf: directory
        .appendingPathComponent("runs/\(run.id.rawValue)/events.jsonl"), encoding: .utf8)
    #expect(events.split(separator: "\n").count == 3)
}

@Test func runManifestRoundTripsAllDurableTaskMetadata() throws {
    let runID = RunID(rawValue: "fixture-run")
    var manifest = RunManifest(
        runID: runID,
        command: ["collider", "build", "runtime"],
        startedAt: "2026-07-22T00:00:00Z")
    manifest.finishedAt = "2026-07-22T00:00:01Z"
    manifest.status = .failed
    manifest.failedTask = TaskID(rawValue: "runtime.build")
    manifest.taskDurationsNanoseconds = ["runtime.build": 123]
    let digest = ArtifactDigest(bytes: [UInt8](repeating: 7, count: 32))
    manifest.activeArtifacts = ["runtime": digest]
    manifest.plannedTasks = ["runtime.build": digest]
    manifest.resumedAt = ["2026-07-22T00:00:00.5Z"]
    manifest.resumeCount = 1

    let decoded = try JSONDecoder().decode(
        RunManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.schema == RunManifest.schemaVersion)
    #expect(decoded.runID == runID)
    #expect(decoded.command == manifest.command)
    #expect(decoded.startedAt == manifest.startedAt)
    #expect(decoded.finishedAt == manifest.finishedAt)
    #expect(decoded.status == manifest.status)
    #expect(decoded.failedTask == manifest.failedTask)
    #expect(decoded.taskDurationsNanoseconds
        == manifest.taskDurationsNanoseconds)
    #expect(decoded.activeArtifacts == manifest.activeArtifacts)
    #expect(decoded.plannedTasks == manifest.plannedTasks)
    #expect(decoded.resumedAt == manifest.resumedAt)
    #expect(decoded.resumeCount == manifest.resumeCount)
}

@Test func interruptedRunResumptionRequiresTheRecordedTaskIdentities() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-resume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "core"])
    let original = [TaskPlanEntry(
        task: TaskID(rawValue: "core.build"),
        identity: ArtifactDigest(bytes: [UInt8](repeating: 1, count: 32)),
        isClean: false,
        explanation: "no prior task state")]
    try await registry.recordPlan(original, in: run)
    try await registry.finish(run, status: .interrupted)

    let resumed = try await registry.resume(run.id)
    try await registry.recordPlan(original, in: resumed)
    let changed = [TaskPlanEntry(
        task: TaskID(rawValue: "core.build"),
        identity: ArtifactDigest(bytes: [UInt8](repeating: 2, count: 32)),
        isClean: false,
        explanation: "input identity changed")]
    await #expect(throws: RunRegistryFailure.self) {
        try await registry.recordPlan(changed, in: resumed)
    }
}

@Test func runRegistryScrubsCredentialsFromDurableRecords() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-redaction-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: [
        "collider", "build", "--token", "command-secret",
        "https://example.invalid/archive?token=query-secret",
    ])
    try await registry.record(
        kind: .taskFailed,
        message: "Authorization: Bearer event-secret",
        in: run)
    try await registry.appendLog(
        Array("Cookie: session=log-secret\n".utf8),
        in: run)

    let manifest = try String(
        contentsOf: directory.appendingPathComponent(
            "runs/\(run.id.rawValue)/manifest.json"),
        encoding: .utf8)
    let events = try String(
        contentsOf: directory.appendingPathComponent(
            "runs/\(run.id.rawValue)/events.jsonl"),
        encoding: .utf8)
    let log = try String(
        contentsOf: directory.appendingPathComponent(
            "runs/\(run.id.rawValue)/run.log"),
        encoding: .utf8)
    let durableRecords = manifest + events + log
    for secret in [
        "command-secret", "query-secret", "event-secret", "log-secret",
    ] {
        #expect(!durableRecords.contains(secret))
    }
    #expect(durableRecords.contains("<redacted>"))
}
