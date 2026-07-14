import Foundation

enum WorkspaceFailure: Error, CustomStringConvertible {
    case message(String)
    case process([String], Int32)

    var description: String {
        switch self {
        case .message(let value): value
        case .process(let command, let status):
            "command failed with exit \(status): \(command.joined(separator: " "))"
        }
    }
}

struct WorkspaceContext: Sendable {
    let root: URL
    let environment: [String: String]

    static func load() throws -> WorkspaceContext {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["NUCLEUS_WORKSPACE_ROOT"], !root.isEmpty else {
            throw WorkspaceFailure.message("NUCLEUS_WORKSPACE_ROOT is not set; invoke through tools/nucleus")
        }
        return WorkspaceContext(root: URL(fileURLWithPath: root), environment: environment)
    }

    func repository(_ name: String) -> URL { root.appendingPathComponent(name) }

    @discardableResult
    func run(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        capture: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = directory ?? root
        process.environment = environment
        let output = Pipe()
        if capture {
            process.standardOutput = output
            process.standardError = output
        } else {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        }
        try process.run()
        // Drain captured output while the child is running. Waiting first can
        // deadlock once verbose generators fill the pipe buffer.
        let capturedData = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        let value = capture
            ? String(decoding: capturedData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard process.terminationStatus == 0 else {
            throw WorkspaceFailure.process([executable] + arguments, process.terminationStatus)
        }
        return value
    }
}
