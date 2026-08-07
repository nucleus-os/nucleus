import ColliderCore
import Foundation
import SystemPackage

enum GitSourceCheckoutHasher {
    static func digest(
        _ checkout: FilePath,
        digestFile: (FilePath, Stat) throws -> ArtifactDigest,
        digestNestedCheckout: (FilePath) throws -> ArtifactDigest
    ) throws -> ArtifactDigest {
        let checkout = checkout.normalizedForComparison()
        let repository = FilePath(
            try git(
                at: checkout,
                arguments: ["rev-parse", "--show-toplevel"]
            ).textOutput
        )
        .normalizedForComparison()
        guard let relative = checkout.relativeSubpath(from: repository) else {
            throw GitSourceCheckoutFailure(
                "Git reported repository root outside source checkout: \(checkout)")
        }
        let treeExpression =
            relative.components.isEmpty
            ? "HEAD^{tree}"
            : "HEAD:\(relative.string)"
        let baseTree = try git(
            at: repository,
            arguments: ["rev-parse", "--verify", treeExpression]
        ).textOutput
        let pathspec = relative.components.isEmpty ? "." : relative.string
        let status = try git(
            at: repository,
            arguments: [
                "status", "--porcelain=v1", "-z", "--untracked-files=all",
                "--ignored=no", "--no-renames", "--", pathspec,
            ])

        var encoder = CanonicalDigestEncoder()
        encoder.append(tag: 1, string: "git-source-checkout")
        encoder.append(tag: 2, string: baseTree)
        let records = try status.output.split(separator: 0).map { record -> DirtyPath in
            guard record.count >= 4, record[record.startIndex + 2] == 0x20 else {
                throw GitSourceCheckoutFailure(
                    "Git returned malformed porcelain status for \(checkout)")
            }
            let bytes = Data(record.dropFirst(3))
            guard let repositoryRelative = String(data: bytes, encoding: .utf8) else {
                throw GitSourceCheckoutFailure(
                    "source checkout contains a non-UTF-8 path: \(checkout)")
            }
            let path = repository.appending(repositoryRelative)
            guard let checkoutRelative = path.relativeSubpath(from: checkout) else {
                throw GitSourceCheckoutFailure(
                    "Git returned a path outside the requested source checkout: \(path)")
            }
            return DirtyPath(
                relative: checkoutRelative.string,
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
            encoder.append(tag: 3, bytes: entry.bytes)
        }
        return ArtifactHasher.digest(bytes: encoder.bytes)
    }
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
