import Foundation

struct RepositoryRun: Codable {
    let runID: String
    let command: [String]
    let startedAt: String
    let finishedAt: String?
    let status: String
    let failedTask: String?
}

private struct RepositoryLogEntry: Codable {
    let path: String
    let contents: String
}

struct RepositoryState {
    let context: WorkspaceContext

    private var runsDirectory: URL {
        URL(fileURLWithPath: context.layout.runs.string, isDirectory: true)
    }

    func runs(kind: String? = nil) throws -> [(URL, RepositoryRun)] {
        guard FileManager.default.fileExists(atPath: runsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
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

    func printStatus() throws {
        guard let (_, run) = try runs().first else {
            try context.console.report(
                IdleRepositoryStatus(status: "idle"),
                text: "status: idle")
            return
        }
        var lines = [
            "run: \(run.runID)",
            "status: \(run.status)",
            "command: \(CommandConsole.render(command: run.command))",
        ]
        if let failedTask = run.failedTask { lines.append("failed task: \(failedTask)") }
        try context.console.report(run, text: lines.joined(separator: "\n"))
    }

    func list(kind: String?) throws {
        let values = try runs(kind: kind)
        let text = values.map { _, run in
            "\(run.runID)\t\(run.status)\t\(domain(of: run))\t"
                + CommandConsole.render(command: Array(run.command.dropFirst()))
        }.joined(separator: "\n")
        try context.console.report(values.map(\.1), text: text)
    }

    func show(_ runID: String?, kind: String?) throws {
        let (directory, _) = try resolve(runID, kind: kind)
        let logs = try retainedLogs(in: directory)
        guard !logs.isEmpty else {
            throw WorkspaceFailure.message(
                "run has no retained logs: \(directory.path)")
        }
        let entries = try logs.map { log in
            RepositoryLogEntry(
                path: relativePath(of: log, in: directory),
                contents: try String(contentsOf: log, encoding: .utf8))
        }
        var text = ""
        for entry in entries {
            if logs.count > 1 {
                text += "==> \(entry.path) <==\n"
            }
            text += entry.contents
            if logs.count > 1 {
                text += "\n"
            }
        }
        try context.console.report(entries, text: text)
    }

    func tail(_ runID: String?, kind: String?) async throws {
        let (directory, _) = try resolve(runID, kind: kind)
        let logs = try retainedLogs(in: directory)
        guard !logs.isEmpty else {
            throw WorkspaceFailure.message(
                "run has no retained logs: \(directory.path)")
        }
        try await context.run(
            "tail",
            ["-n", "200", "-f"] + logs.map(\.path),
            acceptedExitStatuses: [0, interruptedProcessExitStatus])
    }

    private func retainedLogs(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        guard
            let enumerator = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else {
            return []
        }
        var logs: [URL] = []
        for case let candidate as URL in enumerator {
            let relative = relativePath(of: candidate, in: directory)
            guard candidate.pathExtension == "log",
                !relative.hasPrefix("stages/"),
                try candidate.resourceValues(
                    forKeys: [.isRegularFileKey]
                ).isRegularFile == true
            else {
                continue
            }
            logs.append(candidate)
        }
        return logs.sorted {
            let left = relativePath(of: $0, in: directory)
            let right = relativePath(of: $1, in: directory)
            if left == "run.log" || right == "run.log" {
                return left == "run.log" && right != "run.log"
            }
            return left < right
        }
    }

    private func relativePath(of file: URL, in directory: URL) -> String {
        String(file.path.dropFirst(directory.path.count + 1))
    }

    private func domain(of run: RepositoryRun) -> String {
        guard run.command.count > 1 else { return "status" }
        return switch run.command[1] {
        case "swift-sdk": "swift-sdk"
        case "android": "android"
        case "browser": "browser"
        default: "runtime"
        }
    }
}

private struct IdleRepositoryStatus: Codable {
    let status: String
}
