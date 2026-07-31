import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

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
        from: Data(
            contentsOf:
                directory
                .appendingPathComponent("runs/\(run.id.rawValue)/manifest.json")))
    #expect(manifest.status == .succeeded)
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: directory.appendingPathComponent("latest").path)
            == "runs/\(run.id.rawValue)")
    let events = try String(
        contentsOf:
            directory
            .appendingPathComponent("runs/\(run.id.rawValue)/events.jsonl"), encoding: .utf8)
    #expect(events.split(separator: "\n").count == 3)
}

@Test func runRegistryReclaimsOnlySupersededSucceededRuns() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = FileManager.default
    let runs = directory.appendingPathComponent("runs")
    try manager.createDirectory(at: runs, withIntermediateDirectories: true)
    let overflow = 5
    let existing = Int(RunRegistry.retainedRuns) + overflow
    func record(_ id: String, startedAt: String, status: RunStatus) throws {
        let run = runs.appendingPathComponent(id)
        try manager.createDirectory(at: run, withIntermediateDirectories: true)
        var manifest = RunManifest(
            runID: RunID(rawValue: id),
            command: ["collider", "doctor"],
            startedAt: startedAt)
        manifest.status = status
        try JSONEncoder().encode(manifest).write(
            to: run.appendingPathComponent("manifest.json"))
    }
    var oldest: [String] = []
    for index in 0..<existing {
        let id = "2026-01-01T00-00-00Z-\(1_000 + index)"
        // The oldest run of all did not succeed, so it outlives newer successes.
        try record(
            id,
            startedAt: String(format: "2026-01-01T00:00:00.%03dZ", index),
            status: index == 0 ? .failed : .succeeded)
        oldest.append(id)
    }
    // A run still recording belongs to whoever is writing it.
    try record("2020-01-01T00-00-00Z-7", startedAt: "2020-01-01T00:00:00Z", status: .running)

    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "doctor"])

    let remaining = Set(try manager.contentsOfDirectory(atPath: runs.path))
    #expect(remaining.contains(run.id.rawValue))
    #expect(remaining.contains("2020-01-01T00-00-00Z-7"))
    #expect(remaining.contains(oldest[0]))
    for id in oldest[1...overflow] {
        #expect(!remaining.contains(id))
    }
    #expect(remaining.contains(oldest[oldest.count - 1]))
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
    manifest.planningDurationNanoseconds = 42
    manifest.taskDurationsNanoseconds = ["runtime.build": 123]
    let digest = ArtifactDigest(bytes: [UInt8](repeating: 7, count: 32))
    manifest.activeArtifacts = ["runtime": digest]
    manifest.plannedTasks = ["runtime.build": digest]
    manifest.resumedAt = ["2026-07-22T00:00:00.5Z"]
    manifest.resumeCount = 1

    let decoded = try JSONDecoder().decode(
        RunManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.runID == runID)
    #expect(decoded.command == manifest.command)
    #expect(decoded.startedAt == manifest.startedAt)
    #expect(decoded.finishedAt == manifest.finishedAt)
    #expect(decoded.status == manifest.status)
    #expect(decoded.failedTask == manifest.failedTask)
    #expect(
        decoded.planningDurationNanoseconds
            == manifest.planningDurationNanoseconds)
    #expect(
        decoded.taskDurationsNanoseconds
            == manifest.taskDurationsNanoseconds)
    #expect(decoded.activeArtifacts == manifest.activeArtifacts)
    #expect(decoded.plannedTasks == manifest.plannedTasks)
    #expect(decoded.resumedAt == manifest.resumedAt)
    #expect(decoded.resumeCount == manifest.resumeCount)
}

@Test(arguments: [RunStatus.interrupted, .failed])
func unfinishedRunResumptionReusesOnlyMatchingCleanTaskIdentities(
    status: RunStatus
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-resume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "core"])
    let original = [
        TaskPlanEntry(
            task: TaskID(rawValue: "core.build"),
            identity: ArtifactDigest(bytes: [UInt8](repeating: 1, count: 32)),
            isClean: false,
            explanation: "no prior task state",
            coordinates: nil)
    ]
    try await registry.recordPlan(original, in: run)
    try await registry.finish(run, status: status)

    let resumed = try await registry.resume(run.id)
    try await registry.recordPlan(original, in: resumed)
    let changed = [
        TaskPlanEntry(
            task: TaskID(rawValue: "core.build"),
            identity: ArtifactDigest(bytes: [UInt8](repeating: 2, count: 32)),
            isClean: false,
            explanation: "input identity changed",
            coordinates: nil)
    ]
    try await registry.recordPlan(changed, in: resumed)
    let incorrectlyClean = [
        TaskPlanEntry(
            task: TaskID(rawValue: "core.build"),
            identity: ArtifactDigest(bytes: [UInt8](repeating: 3, count: 32)),
            isClean: true,
            explanation: "fixture incorrectly claims reusable state",
            coordinates: nil)
    ]
    await #expect(throws: RunRegistryFailure.self) {
        try await registry.recordPlan(incorrectlyClean, in: resumed)
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
