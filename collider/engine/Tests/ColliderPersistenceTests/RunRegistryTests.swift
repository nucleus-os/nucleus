import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderPersistence

@Test func runRegistryPublishesManifestEventsAndLatest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-registry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "doctor"])
    try await registry.record(
        kind: .taskStarted, task: TaskID(rawValue: "doctor.host"), in: run)
    try await registry.appendLog(Array("diagnostic\n".utf8), in: run)
    try await registry.recordExecutionMetrics(
        criticalPathDurationNanoseconds: 123,
        resourceWaitDurationNanoseconds: 45,
        in: run)
    try await registry.finish(run, status: .succeeded)

    let manifest = try JSONDecoder().decode(
        RunManifest.self,
        from: Data(
            contentsOf:
                directory
                .appendingPathComponent("runs/\(run.id.rawValue)/manifest.json")))
    #expect(manifest.status == .succeeded)
    #expect(manifest.criticalPathDurationNanoseconds == 123)
    #expect(manifest.resourceWaitDurationNanoseconds == 45)
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

@Test func runRegistryPersistsOneUnifiedRecordPerPlannedTask() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-task-record-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let task = TaskID(rawValue: "fixture.build")
    let identity = ArtifactDigest(bytes: [UInt8](repeating: 19, count: 32))
    let plan = TaskPlanEntry(
        task: task,
        identity: identity,
        isClean: false,
        explanation: "no prior task state",
        coordinates: TaskExecutionCoordinates(
            runner: .current,
            execution: .linuxARM64OCI,
            backend: .appleContainer,
            artifact: .linuxARM64),
        audit: fixtureAudit(component: ComponentID(rawValue: "fixture")))
    try await registry.recordPlan([plan], in: run)
    try await registry.recordTaskDuration(88, task: task, in: run)
    try await registry.recordTaskOutcome(.executed, task: task, in: run)
    try await registry.recordArtifactSnapshotDigests(
        ["product": identity],
        task: task,
        in: run)
    try await registry.recordTaskObservations(
        TaskExecutionObservations(
            hardwareProbes: [
                HardwareProbeObservation(name: "fixture.device", result: "present")
            ]),
        task: task,
        in: run)

    let manifest = try JSONDecoder().decode(
        RunManifest.self,
        from: Data(
            contentsOf: directory.appendingPathComponent(
                "runs/\(run.id.rawValue)/manifest.json")))
    let record = try #require(manifest.tasks?[task.rawValue])
    #expect(record.plan.identity == identity)
    #expect(record.outcome == .executed)
    #expect(record.durationNanoseconds == 88)
    #expect(record.artifactSnapshotDigests == ["product": identity])
    #expect(record.observations?.hardwareProbes.first?.result == "present")
}

@Test func runRegistryLeavesReclamationToTheExplicitLifecycleCommand() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = FileManager.default
    let runs = directory.appendingPathComponent("runs")
    try manager.createDirectory(at: runs, withIntermediateDirectories: true)
    let overflow = 5
    let retained = 100
    let existing = retained + overflow
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
        let milliseconds = String(index)
        let paddedMilliseconds =
            String(repeating: "0", count: max(0, 3 - milliseconds.count))
            + milliseconds
        // The oldest run of all did not succeed, so it outlives newer successes.
        try record(
            id,
            startedAt: "2026-01-01T00:00:00.\(paddedMilliseconds)Z",
            status: index == 0 ? .failed : .succeeded)
        oldest.append(id)
    }
    // A run still recording belongs to whoever is writing it.
    try record("2020-01-01T00-00-00Z-7", startedAt: "2020-01-01T00:00:00Z", status: .running)

    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "doctor"])
    let reclaimable = Set(
        await registry.reclaimableRuns(keeping: retained).map(\.id.rawValue))

    let remaining = Set(try manager.contentsOfDirectory(atPath: runs.path))
    #expect(remaining.contains(run.id.rawValue))
    #expect(remaining.contains("2020-01-01T00-00-00Z-7"))
    #expect(remaining.contains(oldest[0]))
    for id in oldest[1...overflow] {
        #expect(remaining.contains(id))
        #expect(reclaimable.contains(id))
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
    manifest.selectedInputHashingDurationNanoseconds = 17
    manifest.swiftPMInvocationCount = 2
    manifest.executionDurationNanoseconds = 99
    let digest = ArtifactDigest(bytes: [UInt8](repeating: 7, count: 32))
    manifest.activeArtifacts = ["runtime": digest]
    let task = TaskID(rawValue: "runtime.build")
    let plan = TaskPlanEntry(
        task: task,
        identity: digest,
        isClean: false,
        explanation: "fixture",
        coordinates: nil,
        audit: fixtureAudit(component: ComponentID(rawValue: "runtime")),
        logicalOwners: [TaskID(rawValue: "runtime.logical")],
        attribution: "runtime release")
    manifest.tasks = [
        task.rawValue: RunTaskRecord(
            plan: plan,
            outcome: .executed,
            durationNanoseconds: 123,
            artifactSnapshotDigests: ["product": digest],
            observations: TaskExecutionObservations(
                containerExecutions: [
                    OCIExecutionObservation(
                        imageDigest: digest,
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: .linuxX86_64,
                        networkPolicy: .externalDisabled,
                        userPolicy: .builder,
                        capabilityPolicy: .dropAll,
                        privilegePolicy: .prohibitAcquisition,
                        processFilesystemPolicy: .standard,
                        intelBinaryTranslationPolicy: .required,
                        resourceLimits: .parallelBuild,
                        status: 0)
                ],
                hardwareProbes: [
                    HardwareProbeObservation(
                        name: "vulkan.gpu-headless",
                        result: "passed")
                ]))
    ]
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
        decoded.selectedInputHashingDurationNanoseconds
            == manifest.selectedInputHashingDurationNanoseconds)
    #expect(decoded.swiftPMInvocationCount == manifest.swiftPMInvocationCount)
    #expect(
        decoded.executionDurationNanoseconds
            == manifest.executionDurationNanoseconds)
    #expect(decoded.activeArtifacts == manifest.activeArtifacts)
    let decodedTask = try #require(decoded.tasks?[task.rawValue])
    #expect(decodedTask.plan.identity == digest)
    #expect(decodedTask.plan.logicalOwners == [TaskID(rawValue: "runtime.logical")])
    #expect(decodedTask.plan.attribution == "runtime release")
    #expect(decodedTask.outcome == .executed)
    #expect(decodedTask.durationNanoseconds == 123)
    #expect(decodedTask.artifactSnapshotDigests == ["product": digest])
    #expect(decodedTask.observations?.containerExecutions.first?.imageDigest == digest)
    #expect(
        decodedTask.observations?.containerExecutions.first?
            .intelBinaryTranslationPolicy == .required)
    #expect(
        decodedTask.observations?.hardwareProbes
            == [HardwareProbeObservation(name: "vulkan.gpu-headless", result: "passed")])
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
            coordinates: nil,
            audit: fixtureAudit(component: ComponentID(rawValue: "core")))
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
            coordinates: nil,
            audit: fixtureAudit(component: ComponentID(rawValue: "core")))
    ]
    try await registry.recordPlan(changed, in: resumed)
    let incorrectlyClean = [
        TaskPlanEntry(
            task: TaskID(rawValue: "core.build"),
            identity: ArtifactDigest(bytes: [UInt8](repeating: 3, count: 32)),
            isClean: true,
            explanation: "fixture incorrectly claims reusable state",
            coordinates: nil,
            audit: fixtureAudit(component: ComponentID(rawValue: "core")))
    ]
    await #expect(throws: RunRegistryFailure.self) {
        try await registry.recordPlan(incorrectlyClean, in: resumed)
    }
}

private func fixtureAudit(component: ComponentID) -> PlannedTaskAudit {
    PlannedTaskAudit(
        component: component,
        actionKind: nil,
        actionIdentity: nil,
        semanticDependencies: [:],
        orderingDependencies: [],
        artifactReferences: [],
        resultReferences: [],
        inputs: [],
        semanticTools: [],
        operationalTools: [],
        swiftBuildContexts: [],
        outputs: [],
        postconditions: [],
        effects: [],
        networkAccess: "none",
        assessmentPolicy: "incremental")
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
    let task = TaskID(rawValue: "fixture.redaction")
    try await registry.recordPlan(
        [
            TaskPlanEntry(
                task: task,
                identity: ArtifactDigest(bytes: [UInt8](repeating: 7, count: 32)),
                isClean: false,
                explanation: "credential redaction fixture",
                coordinates: nil,
                audit: fixtureAudit(component: ComponentID(rawValue: "fixture")))
        ],
        in: run)
    try await registry.recordTaskObservations(
        TaskExecutionObservations(
            hardwareProbes: [
                HardwareProbeObservation(
                    name: "probe?token=observation-name-secret",
                    result: "Authorization: Bearer observation-result-secret")
            ]),
        task: task,
        in: run)
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
        "observation-name-secret", "observation-result-secret",
    ] {
        #expect(!durableRecords.contains(secret))
    }
    #expect(durableRecords.contains("<redacted>"))
}
