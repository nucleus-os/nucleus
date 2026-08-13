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
        let repository = canonicalFileSystemPath(
            FilePath(
                try git(
                    at: first,
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
        let status = try git(
            at: repository,
            arguments: [
                "status", "--porcelain=v1", "-z", "--untracked-files=all",
                "--ignored=no", "--no-renames", "--",
            ] + pathspecs)

        var encoder = IdentityEncoder()
        encoder.append("git-source-checkout-closure")
        let baseTrees = scopes.map { scope -> String? in
            let expression =
                scope.components.isEmpty
                ? "HEAD^{tree}"
                : "HEAD:\(scope.string)"
            return try? git(
                at: repository,
                arguments: ["rev-parse", "--verify", expression]
            ).textOutput
        }
        encoder.appendSequence(Array(zip(scopes, baseTrees))) { entry, pair in
            entry.append(pair.0.string)
            if let baseTree = pair.1 {
                entry.append("tracked")
                entry.append(baseTree)
            } else {
                entry.append("untracked")
            }
        }
        let records = try status.output.split(separator: 0).map { record -> DirtyPath in
            guard record.count >= 4, record[record.startIndex + 2] == 0x20 else {
                throw GitSourceCheckoutFailure(
                    "Git returned malformed porcelain status for \(first)")
            }
            let bytes = Data(record.dropFirst(3))
            guard let repositoryRelative = String(data: bytes, encoding: .utf8) else {
                throw GitSourceCheckoutFailure(
                    "source checkout contains a non-UTF-8 path: \(first)")
            }
            let path = repository.appending(repositoryRelative)
            guard
                scopeStrings.contains(where: {
                    contains(repositoryRelative, in: $0)
                })
            else {
                throw GitSourceCheckoutFailure(
                    "Git returned a path outside the requested source closure: \(path)")
            }
            return DirtyPath(
                relative: repositoryRelative,
                absolute: path)
        }.sorted {
            $0.relative.utf8.lexicographicallyPrecedes($1.relative.utf8)
        }

        try encoder.appendSequence(records) { entry, dirty in
            entry.append(dirty.relative)
            do {
                let metadata = try dirty.absolute.stat(followTargetSymlink: false)
                entry.append(metadata.permissions.contains(.ownerExecute) ? 1 : 0)
                switch metadata.type {
                case .regular:
                    entry.append("file")
                    entry.append(bytes: try digestFile(dirty.absolute, metadata).bytes)
                case .symbolicLink:
                    entry.append("symlink")
                    entry.append(
                        try FileManager.default.destinationOfSymbolicLink(
                            atPath: dirty.absolute.string))
                case .directory:
                    if (try? dirty.absolute.appending(".git").stat(
                        followTargetSymlink: false)) != nil
                    {
                        entry.append("nested-checkout")
                        entry.append(bytes: try digestNestedCheckout(dirty.absolute).bytes)
                    } else {
                        entry.append("directory")
                    }
                default:
                    entry.append("other:\(metadata.type.rawValue)")
                }
            } catch let error as Errno where error == .noSuchFileOrDirectory {
                entry.append("deleted")
            }
        }
        return ArtifactHasher.digest(bytes: encoder.bytes)
    }
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

private struct DirtyPath {
    let relative: String
    let absolute: FilePath
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
