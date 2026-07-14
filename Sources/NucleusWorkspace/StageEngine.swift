import Foundation

private struct StageRecord: Codable { let fingerprint: String; let completedAt: Date }

struct BootstrapStage {
    let name: String
    let inputs: [String]
    let outputs: [String]
    let run: () throws -> Void
}

struct StageEngine {
    let context: WorkspaceContext

    func execute(_ stages: [BootstrapStage], force: Bool = false) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        for stage in stages {
            let fingerprint = try fingerprint(stage)
            if !force, current(stage, fingerprint: fingerprint) {
                print("==> \(stage.name) (current)")
                continue
            }
            if let data = try? Data(contentsOf: recordURL(stage)),
               let record = try? JSONDecoder.stage.decode(StageRecord.self, from: data) {
                print("    fingerprint changed: \(record.fingerprint.prefix(12)) -> \(fingerprint.prefix(12))")
            }
            print("==> \(stage.name)")
            try stage.run()
            guard outputsExist(stage) else { throw WorkspaceFailure.message("stage '\(stage.name)' did not produce all declared outputs") }
            // Synchronization and generation stages may intentionally update their
            // declared inputs. Persist the resulting state, not the stale pre-run key.
            let completedFingerprint = try self.fingerprint(stage)
            let data = try JSONEncoder.pretty.encode(StageRecord(fingerprint: completedFingerprint, completedAt: Date()))
            try data.write(to: recordURL(stage), options: .atomic)
        }
    }

    private var stateDirectory: URL { context.root.appendingPathComponent(".nucleus/state") }
    private func recordURL(_ stage: BootstrapStage) -> URL { stateDirectory.appendingPathComponent(stage.name + ".json") }
    private func outputsExist(_ stage: BootstrapStage) -> Bool {
        stage.outputs.allSatisfy { FileManager.default.fileExists(atPath: context.root.appendingPathComponent($0).path) }
    }
    private func current(_ stage: BootstrapStage, fingerprint: String) -> Bool {
        guard outputsExist(stage), let data = try? Data(contentsOf: recordURL(stage)),
              let record = try? JSONDecoder.stage.decode(StageRecord.self, from: data) else { return false }
        return record.fingerprint == fingerprint
    }
    private func fingerprint(_ stage: BootstrapStage) throws -> String {
        var lines = [stage.name]
        lines.append(try context.run("sha256sum", [context.root.appendingPathComponent("config/build-contract.json").path], capture: true))
        for input in stage.inputs.sorted() {
            let url = context.root.appendingPathComponent(input)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let index = try context.run("git", ["ls-files", "-s", "--", input], directory: context.root, capture: true)
                // Hash tracked content changes without transient nested-repository
                // dirtiness from dependency synchronizers.
                let changes = index.hasPrefix("160000 ") ? "" : try context.run("git", ["diff", "--no-ext-diff", "--binary", "HEAD", "--", input], directory: context.root, capture: true)
                lines.append(input + "\n" + index + "\n" + changes)
            } else if FileManager.default.fileExists(atPath: url.path) {
                lines.append(try context.run("sha256sum", [url.path], capture: true))
            } else { lines.append(input + ":missing") }
        }
        return try context.run("sh", ["-c", "printf '%s' \"$1\" | sha256sum | cut -d' ' -f1", "sh", lines.joined(separator: "\n")], capture: true)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; value.dateEncodingStrategy = .iso8601; return value }
}

private extension JSONDecoder {
    static var stage: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
