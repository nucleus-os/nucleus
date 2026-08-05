import ColliderCore
import Foundation
import SystemPackage

public struct TaskStateSnapshot: Sendable {
    private let records: [TaskID: TaskStateRecord]
    private let corruptFileNames: Set<String>

    public init(root: FilePath) throws {
        guard FileManager.default.fileExists(atPath: root.string) else {
            records = [:]
            corruptFileNames = []
            return
        }
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: root.string)
            .filter { $0.hasSuffix(".json") && $0 != "artifact-digests.json" }
        var loaded: [TaskID: TaskStateRecord] = [:]
        var corrupt: Set<String> = []
        for fileName in fileNames {
            let path = root.appending(fileName)
            guard
                let data = try? Data(contentsOf: URL(fileURLWithPath: path.string)),
                let record = try? JSONDecoder().decode(TaskStateRecord.self, from: data),
                stateFileName(for: record.task) == fileName
            else {
                corrupt.insert(fileName)
                continue
            }
            loaded[record.task] = record
        }
        records = loaded
        corruptFileNames = corrupt
    }

    public func lookup(_ task: TaskID) -> PlanningTaskState {
        if let record = records[task] {
            return .record(record)
        }
        if corruptFileNames.contains(stateFileName(for: task)) {
            return .corrupt
        }
        return .missing
    }
}

public struct TaskStateStore: Sendable {
    public let root: FilePath

    public init(root: FilePath) {
        self.root = root
    }

    public func snapshot() throws -> TaskStateSnapshot {
        try TaskStateSnapshot(root: root)
    }

    public func persist(_ record: TaskStateRecord) throws {
        try DurableFile.writeJSON(record, to: path(for: record.task))
    }

    public func path(for task: TaskID) -> FilePath {
        root.appending(stateFileName(for: task))
    }
}

private func stateFileName(for task: TaskID) -> String {
    task.rawValue.map {
        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
    }.reduce(into: "") { $0.append($1) } + ".json"
}
