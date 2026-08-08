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
        let checkouts = Array(Set(checkouts.map { $0.normalizedForComparison() }))
            .sorted { $0.string < $1.string }
        guard let first = checkouts.first else {
            throw GitSourceCheckoutFailure("source closure is empty")
        }
        let repository = FilePath(
            try git(
                at: first,
                arguments: ["rev-parse", "--show-toplevel"]
            ).textOutput
        )
        .normalizedForComparison()
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

        var encoder = CanonicalDigestEncoder()
        encoder.append(tag: 1, string: "git-source-checkout-closure")
        let treeExpressions = scopes.map { scope in
            scope.components.isEmpty
                ? "HEAD^{tree}"
                : "HEAD:\(scope.string)"
        }
        let baseTrees = try git(
            at: repository,
            arguments: ["rev-parse"] + treeExpressions
        ).textOutput.split(separator: "\n").map(String.init)
        guard baseTrees.count == scopes.count else {
            throw GitSourceCheckoutFailure(
                "Git returned \(baseTrees.count) trees for \(scopes.count) source scopes")
        }
        for (scope, baseTree) in zip(scopes, baseTrees) {
            encoder.append(tag: 2, string: scope.string)
            encoder.append(tag: 3, string: baseTree)
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

        for dirty in records {
            var entry = CanonicalDigestEncoder()
            entry.append(tag: 1, string: dirty.relative)
            do {
                let metadata = try dirty.absolute.stat(followTargetSymlink: false)
                entry.append(
                    tag: 2,
                    integer: metadata.permissions.contains(.ownerExecute) ? 1 : 0)
                switch metadata.type {
                case .regular:
                    entry.append(tag: 3, string: "file")
                    entry.append(
                        tag: 4,
                        bytes: try digestFile(dirty.absolute, metadata).bytes)
                case .symbolicLink:
                    entry.append(tag: 3, string: "symlink")
                    entry.append(
                        tag: 4,
                        string: try FileManager.default.destinationOfSymbolicLink(
                            atPath: dirty.absolute.string))
                case .directory:
                    if (try? dirty.absolute.appending(".git").stat(
                        followTargetSymlink: false)) != nil
                    {
                        entry.append(tag: 3, string: "nested-checkout")
                        entry.append(
                            tag: 4,
                            bytes: try digestNestedCheckout(dirty.absolute).bytes)
                    } else {
                        entry.append(tag: 3, string: "directory")
                    }
                default:
                    entry.append(
                        tag: 3,
                        string: "other:\(metadata.type.rawValue)")
                }
            } catch let error as Errno where error == .noSuchFileOrDirectory {
                entry.append(tag: 3, string: "deleted")
            }
            encoder.append(tag: 4, bytes: entry.bytes)
        }
        return ArtifactHasher.digest(bytes: encoder.bytes)
    }
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
