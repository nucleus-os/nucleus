import ColliderCore
import Foundation
import SystemPackage

enum GitSourceCheckoutHasher {
    static func digest(
        _ checkout: FilePath,
        digestFile: (FilePath, Stat) throws -> ArtifactDigest,
        digestNestedCheckout: (FilePath) throws -> ArtifactDigest
    ) throws -> ArtifactDigest {
        try digest(
            [checkout],
            digestFile: digestFile,
            digestNestedCheckout: digestNestedCheckout)
    }

    static func digest(
        _ checkouts: [FilePath],
        digestFile: (FilePath, Stat) throws -> ArtifactDigest,
        digestNestedCheckout: (FilePath) throws -> ArtifactDigest
    ) throws -> ArtifactDigest {
        let checkouts = Array(Set(checkouts.map { canonicalFileSystemPath($0) }))
            .sorted { $0.string < $1.string }
        guard let first = checkouts.first else {
            throw GitSourceCheckoutFailure("source closure is empty")
        }
        let inspectionDirectory: FilePath
        if (try? first.stat(followTargetSymlink: false).type) == .directory {
            inspectionDirectory = first
        } else {
            inspectionDirectory = first.removingLastComponent()
        }
        let repository = canonicalFileSystemPath(
            FilePath(
                try git(
                    at: inspectionDirectory,
                    arguments: ["rev-parse", "--show-toplevel"]
                ).textOutput
            ))
        let relatives = try checkouts.map { checkout -> FilePath in
            guard let relative = checkout.relativeSubpath(from: repository) else {
                throw GitSourceCheckoutFailure(
                    "Git reported repository root outside source closure: \(checkout)")
            }
            return relative
        }
        var scopes: [FilePath] = []
        for candidate in relatives.sorted(by: {
            let leftCount = $0.components.count
            let rightCount = $1.components.count
            return leftCount == rightCount
                ? $0.string < $1.string
                : leftCount < rightCount
        }) {
            guard
                !scopes.contains(where: {
                    contains(candidate.string, in: $0.string)
                })
            else { continue }
            scopes.append(candidate)
        }
        scopes.sort { $0.string < $1.string }
        let scopeStrings = scopes.map(\.string)
        let pathspecs = scopes.map {
            $0.components.isEmpty ? "." : $0.string
        }
        let listedPaths = try git(
            at: repository,
            arguments: [
                "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--",
            ] + pathspecs)
        let trackedModes = try trackedModes(
            repository: repository,
            pathspecs: pathspecs)

        var encoder = IdentityEncoder()
        encoder.append("git-source-checkout-closure")
        encoder.appendSequence(scopes) { entry, scope in
            entry.append(scope.string)
        }
        let listedRelativePaths = try listedPaths.output.split(separator: 0).map {
            record in
            guard let repositoryRelative = String(data: Data(record), encoding: .utf8)
            else {
                throw GitSourceCheckoutFailure(
                    "source checkout contains a non-UTF-8 path: \(first)")
            }
            guard
                scopeStrings.contains(where: {
                    contains(repositoryRelative, in: $0)
                })
            else {
                throw GitSourceCheckoutFailure(
                    "Git returned a path outside the requested source closure: "
                        + repository.appending(repositoryRelative).string)
            }
            return repositoryRelative
        }
        let paths = try Set(listedRelativePaths).filter { relative in
            let path = repository.appending(relative)
            do {
                _ = try path.stat(followTargetSymlink: false)
                return true
            } catch let error as Errno where error == .noSuchFileOrDirectory {
                guard trackedModes[relative] == "160000" else {
                    // Deleted tracked files are not members of the effective tree.
                    return false
                }
                throw GitSourceCheckoutFailure(
                    "nested checkout is not materialized: \(path)")
            }
        }.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }

        try encoder.appendSequence(paths) { entry, relative in
            let path = repository.appending(relative)
            let metadata = try path.stat(followTargetSymlink: false)
            entry.append(relative)
            entry.append(metadata.permissions.contains(.ownerExecute))
            switch metadata.type {
            case .regular:
                entry.append("file")
                entry.append(bytes: try digestFile(path, metadata).bytes)
            case .symbolicLink:
                entry.append("symlink")
                entry.append(
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: path.string))
            case .directory:
                if (try? path.appending(".git").stat(
                    followTargetSymlink: false)) != nil
                {
                    entry.append("nested-checkout")
                    entry.append(bytes: try digestNestedCheckout(path).bytes)
                } else {
                    entry.append("directory")
                }
            default:
                entry.append("other:\(metadata.type.rawValue)")
            }
        }
        return ArtifactHasher.digest(bytes: encoder.bytes)
    }
}

private func trackedModes(
    repository: FilePath,
    pathspecs: [String]
) throws -> [String: String] {
    let result = try git(
        at: repository,
        arguments: ["ls-files", "--stage", "-z", "--"] + pathspecs)
    var modes: [String: String] = [:]
    for record in result.output.split(separator: 0) {
        guard let tab = record.firstIndex(of: 0x09) else {
            throw GitSourceCheckoutFailure(
                "Git returned malformed staged-path data for \(repository)")
        }
        let fields = record[..<tab].split(separator: 0x20)
        let pathBytes = record[record.index(after: tab)...]
        guard fields.count == 3,
            let mode = String(data: Data(fields[0]), encoding: .utf8),
            let path = String(data: Data(pathBytes), encoding: .utf8)
        else {
            throw GitSourceCheckoutFailure(
                "Git returned malformed staged-path data for \(repository)")
        }
        modes[path] = mode
    }
    return modes
}

private func canonicalFileSystemPath(_ path: FilePath) -> FilePath {
    FilePath(
        URL(fileURLWithPath: path.string)
            .resolvingSymlinksInPath()
            .path
    ).normalizedForComparison()
}

private func contains(_ candidate: String, in parent: String) -> Bool {
    parent.isEmpty || candidate == parent || candidate.hasPrefix(parent + "/")
}

private struct GitResult {
    let output: Data

    var textOutput: String {
        String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func git(
    at directory: FilePath,
    arguments: [String]
) throws -> GitResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = URL(fileURLWithPath: directory.string)
    process.arguments = ["--no-optional-locks"] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["LC_ALL"] = "C"
    process.environment = environment
    process.standardOutput = standardOutput
    process.standardError = standardError
    do {
        try process.run()
    } catch {
        throw GitSourceCheckoutFailure(
            "could not execute Git for \(directory): \(error)")
    }
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: errorOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw GitSourceCheckoutFailure(
            "Git failed for \(directory): \(message)")
    }
    return GitResult(output: output)
}

struct GitSourceCheckoutFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = "source checkout identity failed: \(description)"
    }
}
