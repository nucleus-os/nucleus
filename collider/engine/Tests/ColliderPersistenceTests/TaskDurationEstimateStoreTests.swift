import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage
import Testing

@Test func durationEstimateStoreIsRollingBoundedAndDisposable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-duration-estimates-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskDurationEstimateStore(root: FilePath(directory.path))
    let workload = durationWorkload(task: "fixture.build", lane: .lightweight)
    let identity = ArtifactDigest(bytes: [1])
    let plan = [durationPlan(workload: workload, identity: identity)]

    #expect(store.snapshot().estimate(for: workload) == nil)
    for sample in 1...9 {
        try store.record(
            [workload.task: UInt64(sample) * 1_000],
            plan: plan)
    }
    #expect(store.snapshot().estimate(for: workload) == 5_500)

    let sourceChangedPlan = [
        durationPlan(
            workload: workload,
            identity: ArtifactDigest(bytes: [2]))
    ]
    try store.record([workload.task: 10_000], plan: sourceChangedPlan)
    #expect(store.snapshot().estimate(for: workload) == 6_500)

    let unknownOCI = durationWorkload(task: "fixture.oci", lane: .oci)
    #expect(store.snapshot().estimate(for: unknownOCI) == 60_000_000_000)

    try FileManager.default.removeItem(at: directory)
    #expect(store.snapshot().estimate(for: workload) == nil)
}

@Test func durationEstimateStoreBoundsWorkloadsAndTreatsCorruptionAsEmpty() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-duration-estimate-bound-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskDurationEstimateStore(root: FilePath(directory.path))
    let identity = ArtifactDigest(bytes: [3])
    var durations: [TaskID: UInt64] = [:]
    var plan: [TaskPlanEntry] = []
    for index in 0...TaskDurationEstimateStore.maximumWorkloads {
        let workload = durationWorkload(task: "fixture.\(index)", lane: .lightweight)
        durations[workload.task] = UInt64(index + 1)
        plan.append(durationPlan(workload: workload, identity: identity))
    }
    try store.record(durations, plan: plan)
    let data = try Data(
        contentsOf: directory.appendingPathComponent("history.json"))
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any])
    let records = try #require(object["records"] as? [[String: Any]])
    #expect(records.count == TaskDurationEstimateStore.maximumWorkloads)

    try Data("not json".utf8).write(
        to: directory.appendingPathComponent("history.json"))
    #expect(
        store.snapshot().estimate(
            for: durationWorkload(task: "fixture.1", lane: .lightweight)) == nil)
}

private func durationWorkload(
    task: String,
    lane: TaskExecutionLane
) -> TaskDurationWorkload {
    TaskDurationWorkload(
        task: TaskID(rawValue: task),
        lane: lane,
        coordinates: nil,
        mode: "release")
}

private func durationPlan(
    workload: TaskDurationWorkload,
    identity: ArtifactDigest
) -> TaskPlanEntry {
    TaskPlanEntry(
        task: workload.task,
        identity: identity,
        isClean: false,
        explanation: "dirty",
        coordinates: workload.coordinates,
        lane: workload.lane,
        durationWorkload: workload)
}
