import ColliderCore
import Foundation
import SystemPackage

public struct TaskDurationEstimateSnapshot: Sendable {
    fileprivate let records: [TaskDurationWorkload: TaskDurationEstimateRecord]

    public static let empty = TaskDurationEstimateSnapshot(records: [:])

    public func estimate(for workload: TaskDurationWorkload) -> UInt64? {
        if let exact = records[workload] {
            return median(exact.samples)
        }
        guard !records.isEmpty else { return nil }
        let laneSamples = records.values
            .filter { $0.workload.lane == workload.lane }
            .compactMap { median($0.samples) }
        if let laneEstimate = median(laneSamples) { return laneEstimate }
        return switch workload.lane {
        case .lightweight: 1_000_000_000
        case .hostExclusive: 10_000_000_000
        case .oci: 60_000_000_000
        }
    }
}

public struct TaskDurationEstimateStore: Sendable {
    public static let maximumWorkloads = 512
    public static let maximumSamplesPerWorkload = 8

    public let root: FilePath

    public init(root: FilePath) {
        self.root = root
    }

    public func snapshot() -> TaskDurationEstimateSnapshot {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path.string)),
            let archive = try? JSONDecoder().decode(TaskDurationEstimateArchive.self, from: data)
        else { return .empty }
        return TaskDurationEstimateSnapshot(
            records: Dictionary(
                archive.records.map { ($0.workload, $0) },
                uniquingKeysWith: { left, right in
                    left.sequence >= right.sequence ? left : right
                }))
    }

    public func record(
        _ durations: [TaskID: UInt64],
        plan: [TaskPlanEntry]
    ) throws {
        guard !durations.isEmpty else { return }
        var records = snapshot().records
        var sequence = records.values.map(\.sequence).max() ?? 0
        let workloads = Dictionary(
            uniqueKeysWithValues: plan.compactMap { entry in
                entry.durationWorkload.map { (entry.task, $0) }
            })
        for (task, duration) in durations.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard duration > 0,
                let workload = workloads[task]
            else { continue }
            sequence &+= 1
            var samples = records[workload]?.samples ?? []
            samples.append(duration)
            if samples.count > Self.maximumSamplesPerWorkload {
                samples.removeFirst(samples.count - Self.maximumSamplesPerWorkload)
            }
            records[workload] = TaskDurationEstimateRecord(
                workload: workload,
                samples: samples,
                sequence: sequence)
        }
        let bounded = records.values.sorted {
            if $0.sequence == $1.sequence {
                return workloadSortKey($0.workload) < workloadSortKey($1.workload)
            }
            return $0.sequence > $1.sequence
        }.prefix(Self.maximumWorkloads)
        let archive = TaskDurationEstimateArchive(
            records: bounded.sorted {
                workloadSortKey($0.workload) < workloadSortKey($1.workload)
            })
        try FileManager.default.createDirectory(
            atPath: root.string,
            withIntermediateDirectories: true)
        try DurableFile.writeJSON(archive, to: path)
    }

    private var path: FilePath {
        root.appending("history.json")
    }
}

private struct TaskDurationEstimateArchive: Codable, Sendable {
    let records: [TaskDurationEstimateRecord]
}

private struct TaskDurationEstimateRecord: Codable, Sendable {
    let workload: TaskDurationWorkload
    let samples: [UInt64]
    let sequence: UInt64
}

private func median(_ values: [UInt64]) -> UInt64? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
    let left = sorted[middle - 1]
    let right = sorted[middle]
    return left / 2 + right / 2 + (left % 2 + right % 2) / 2
}

private func workloadSortKey(_ workload: TaskDurationWorkload) -> String {
    let coordinates =
        workload.coordinates.map {
            "\($0.runner.operatingSystem.rawValue)/\($0.runner.architecture.rawValue):"
                + "\($0.backend.rawValue):"
                + "\($0.execution.operatingSystem.rawValue)/"
                + $0.execution.architecture.rawValue
        } ?? "none"
    return "\(workload.task.rawValue)|\(workload.lane.rawValue)|"
        + "\(coordinates)|\(workload.mode ?? "")"
}
