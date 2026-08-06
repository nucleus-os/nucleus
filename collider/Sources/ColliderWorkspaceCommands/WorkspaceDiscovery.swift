import Foundation
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

let interruptedProcessExitStatus = 128 + Int32(SIGINT)

package enum WorkspaceFailure: Error, CustomStringConvertible, Sendable {
    case message(String)
    case process([String], Int32)

    package var description: String {
        switch self {
        case .message(let value): value
        case .process(let command, let status):
            "command failed with exit \(status): \(command.joined(separator: " "))"
        }
    }
}

func discoverWorkspaceRoot(from start: String) -> FilePath? {
    var directory = URL(fileURLWithPath: start).standardizedFileURL
    let fileManager = FileManager.default
    while true {
        let marker = directory.appendingPathComponent("collider-setup.sh").path
        let manifest = directory.appendingPathComponent("collider/Package.swift").path
        if fileManager.fileExists(atPath: marker),
            fileManager.fileExists(atPath: manifest)
        {
            return FilePath(directory)
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return nil }
        directory = parent
    }
}

package func resolveWorkspaceRoot(environment: [String: String]) throws -> FilePath {
    if let root = environment["NUCLEUS_WORKSPACE_ROOT"], !root.isEmpty {
        return FilePath(root)
    }
    if let discovered = discoverWorkspaceRoot(
        from: FileManager.default.currentDirectoryPath)
    {
        return discovered
    }
    throw WorkspaceFailure.message(
        "collider must be run inside a Nucleus workspace "
            + "(no clone at or above the current directory)")
}

package func resolveWorkspacePath(_ value: String, relativeTo root: FilePath) -> FilePath {
    FilePath(
        URL(
            fileURLWithPath: value,
            relativeTo: URL(root, isDirectory: true)
        ).standardizedFileURL)
}
