import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

extension JSONEncoder {
    /// The single stable machine-readable encoding used by every `--json` path.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// The task-graph presentation controls shared by every workflow that drives
/// the Collider task runtime.
struct TaskControls: Sendable {
    var dryRun = false
    var explain = false
    var verbose = false
    var json = false

    var executionOptions: TaskExecutionOptions {
        TaskExecutionOptions(
            dryRun: dryRun,
            explain: explain,
            verbose: verbose,
            machineReadable: json)
    }

    /// Emit the machine-readable report or the clean/dirty plan. Callers add
    /// their own success line for the plain (non-plan, non-JSON) case.
    func render(_ report: TaskExecutionReport) throws {
        if json {
            print(String(
                decoding: try JSONEncoder.sorted.encode(report),
                as: UTF8.self))
        } else if dryRun || explain {
            for entry in report.plan {
                print(
                    "\(entry.isClean ? "clean" : "dirty")  "
                        + "\(entry.task.rawValue)  \(entry.explanation)")
            }
        }
    }
}

extension WorkspaceContext {
    /// The user cache root: `$XDG_CACHE_HOME`, else `$HOME/.cache`, else the
    /// process home directory's `.cache`.
    var cacheRoot: URL {
        if let value = environment["XDG_CACHE_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".cache", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
    }

    /// Build the task graph, execute the selected tasks against the repository
    /// task-state root, render the report, and return it.
    @discardableResult
    func execute(
        tasks: [TaskDeclaration],
        selected: [TaskID],
        controls: TaskControls,
        workflowLocks: [TaskLock] = []
    ) throws -> TaskExecutionReport {
        let graph = try TaskGraph(tasks)
        let stateRoot = FilePath(
            root.appendingPathComponent(".nucleus/tasks").path)
        let report = try waitForAsyncResult {
            try await runtime.execute(
                graph: graph,
                selected: selected,
                stateRoot: stateRoot,
                workflowLocks: workflowLocks,
                options: controls.executionOptions)
        }
        try controls.render(report)
        return report
    }
}
