import Foundation

struct RepositoryRun: Codable {
    let runID: String
    let command: [String]
    let startedAt: String
    let finishedAt: String?
    let status: String
    let failedTask: String?
}

struct RepositoryState {
    let context: WorkspaceContext

    private var runsDirectory: URL {
        context.root.appendingPathComponent(".nucleus/runs", isDirectory: true)
    }

    func runs(kind: String? = nil) throws -> [(URL, RepositoryRun)] {
        guard FileManager.default.fileExists(atPath: runsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .compactMap { directory in
                let manifest = directory.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifest),
                      let run = try? JSONDecoder().decode(RepositoryRun.self, from: data),
                      !["logs", "status"].contains(run.command.dropFirst().first),
                      kind == nil || domain(of: run) == kind
                else { return nil }
                return (directory, run)
            }
            .sorted { $0.1.startedAt > $1.1.startedAt }
    }

    func resolve(_ requested: String?, kind: String? = nil) throws -> (URL, RepositoryRun) {
        if requested == nil || requested == "latest" {
            guard let latest = try runs(kind: kind).first else {
                throw WorkspaceFailure.message("no matching Collider runs")
            }
            return latest
        }
        guard let value = try runs(kind: kind).first(where: { $0.1.runID == requested }) else {
            throw WorkspaceFailure.message("unknown Collider run '\(requested!)'")
        }
        return value
    }

    func printStatus(json: Bool) throws {
        guard let (_, run) = try runs().first else {
            print(json ? #"{"status":"idle"}"# : "status: idle")
            return
        }
        if json {
            let data = try JSONEncoder.sorted.encode(run)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("run: \(run.runID)")
            print("status: \(run.status)")
            print("command: \(run.command.joined(separator: " "))")
            if let failedTask = run.failedTask { print("failed task: \(failedTask)") }
        }
    }

    func list(kind: String?, json: Bool) throws {
        let values = try runs(kind: kind)
        if json {
            let data = try JSONEncoder.sorted.encode(values.map(\.1))
            print(String(decoding: data, as: UTF8.self))
        } else {
            for (_, run) in values {
                print("\(run.runID)\t\(run.status)\t\(domain(of: run))\t\(run.command.dropFirst().joined(separator: " "))")
            }
        }
    }

    func show(_ runID: String?, kind: String?) throws {
        let (directory, _) = try resolve(runID, kind: kind)
        let log = directory.appendingPathComponent("run.log")
        guard FileManager.default.fileExists(atPath: log.path) else {
            throw WorkspaceFailure.message("run has no log: \(log.path)")
        }
        print(try String(contentsOf: log, encoding: .utf8), terminator: "")
    }

    func tail(_ runID: String?, kind: String?) throws {
        let (directory, _) = try resolve(runID, kind: kind)
        let log = directory.appendingPathComponent("run.log")
        try context.run("tail", ["-n", "200", "-f", log.path])
    }

    private func domain(of run: RepositoryRun) -> String {
        guard run.command.count > 1 else { return "status" }
        return switch run.command[1] {
        case "toolchain": "toolchain"
        case "android": "android"
        case "browser": "browser"
        default: "runtime"
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return value
    }
}
