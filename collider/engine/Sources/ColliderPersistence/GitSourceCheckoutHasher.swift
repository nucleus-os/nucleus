import ColliderCore
import Foundation
import SystemPackage

/// What one checkout contributed to a source closure, reported before its
/// content is read.
///
/// Capture is not a task, so nothing renders progress for it. A capture is slow
/// in proportion to the paths Git cannot identify, and reporting that count
/// before reading them separates a capture working through a dirty tree from
/// one that has stalled.
public struct SourceCaptureProgress: Sendable, Equatable {
    public let checkout: FilePath
    /// Paths whose identity came from Git without being read.
    public let identifiedPaths: Int
    /// Paths whose content must be read.
    public let inspectedPaths: Int

    public init(checkout: FilePath, identifiedPaths: Int, inspectedPaths: Int) {
        self.checkout = checkout
        self.identifiedPaths = identifiedPaths
        self.inspectedPaths = inspectedPaths
    }
}

public typealias SourceCaptureObserver = (SourceCaptureProgress) -> Void

enum GitSourceCheckoutHasher {
    static func digest(
        _ checkout: FilePath,
        digestFile: (FilePath, Stat) throws -> ArtifactDigest,
        digestNestedCheckout: (FilePath) throws -> ArtifactDigest,
        observe: SourceCaptureObserver? = nil
    ) throws -> ArtifactDigest {
        try digest(
            [checkout],
            digestFile: digestFile,
            digestNestedCheckout: digestNestedCheckout,
            observe: observe)
    }

    static func digest(
        _ checkouts: [FilePath],
        digestFile: (FilePath, Stat) throws -> ArtifactDigest,
        digestNestedCheckout: (FilePath) throws -> ArtifactDigest,
        observe: SourceCaptureObserver? = nil
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
        let tracked = try trackedEntries(
            repository: repository,
            pathspecs: pathspecs)
        let modified = try modifiedPaths(
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
            if gitIdentifiedMode(tracked[relative], modified: modified, path: relative) != nil {
                return true
            }
            let path = repository.appending(relative)
            do {
                _ = try path.stat(followTargetSymlink: false)
                return true
            } catch let error as Errno where error == .noSuchFileOrDirectory {
                guard tracked[relative]?.mode == "160000" else {
                    // Deleted tracked files are not members of the effective tree.
                    return false
                }
                throw GitSourceCheckoutFailure(
                    "nested checkout is not materialized: \(path)")
            }
        }.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }

        // Reported before any content is read, so the cost still to come is
        // visible rather than inferred from a command that appears stalled.
        if let observe {
            let identified = paths.count {
                gitIdentifiedMode(tracked[$0], modified: modified, path: $0) != nil
            }
            observe(
                SourceCaptureProgress(
                    checkout: repository,
                    identifiedPaths: identified,
                    inspectedPaths: paths.count - identified))
        }

        try encoder.appendSequence(paths) { entry, relative in
            let indexEntry = tracked[relative]
            // Content Git already identifies is never touched. The index holds
            // an object identity for exactly the bytes on disk, and the mode
            // gives the type and executable bit, whenever the path is tracked
            // and does not differ from the index. The discriminator keeps
            // object identities and content digests in separate domains so one
            // can never be read as the other.
            if let mode = gitIdentifiedMode(indexEntry, modified: modified, path: relative),
                let indexEntry, mode != "160000"
            {
                entry.append(relative)
                entry.append(mode == "100755")
                entry.append(mode.gitEntryKind)
                if mode == "120000" {
                    entry.append(
                        try FileManager.default.destinationOfSymbolicLink(
                            atPath: repository.appending(relative).string))
                } else {
                    entry.append(indexEntry.object)
                }
                return
            }
            let path = repository.appending(relative)
            let metadata = try path.stat(followTargetSymlink: false)
            entry.append(relative)
            entry.append(metadata.permissions.contains(.ownerExecute))
            switch metadata.type {
            case .regular:
                entry.append("file")
                entry.append(try gitObjectIdentity(repository: repository, path: path))
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

/// One index entry: the mode Git records and the object identity of the
/// content it holds.
struct TrackedEntry {
    let mode: String
    let object: String
}

private func trackedEntries(
    repository: FilePath,
    pathspecs: [String]
) throws -> [String: TrackedEntry] {
    let result = try git(
        at: repository,
        arguments: ["ls-files", "-v", "--stage", "-z", "--"] + pathspecs)
    var entries: [String: TrackedEntry] = [:]
    for record in result.output.split(separator: 0) {
        guard let tab = record.firstIndex(of: 0x09) else {
            throw GitSourceCheckoutFailure(
                "Git returned malformed staged-path data for \(repository)")
        }
        let fields = record[..<tab].split(separator: 0x20)
        let pathBytes = record[record.index(after: tab)...]
        guard fields.count == 4,
            let tag = String(data: Data(fields[0]), encoding: .utf8)?.first,
            let mode = String(data: Data(fields[1]), encoding: .utf8),
            let object = String(data: Data(fields[2]), encoding: .utf8),
            let path = String(data: Data(pathBytes), encoding: .utf8)
        else {
            throw GitSourceCheckoutFailure(
                "Git returned malformed staged-path data for \(repository)")
        }
        // Lowercase tags mark assume-unchanged; S marks skip-worktree. Both
        // instruct Git to report a path as unmodified without inspecting it,
        // which an identity contract cannot accept.
        guard !tag.isLowercase, tag != "S" else {
            throw GitSourceCheckoutFailure(
                "source checkout marks a path unverifiable with assume-unchanged "
                    + "or skip-worktree, so its identity cannot be established: "
                    + path)
        }
        entries[path] = TrackedEntry(mode: mode, object: object)
    }
    return entries
}

/// Paths whose working-tree content differs from the index.
///
/// Git re-reads content for entries whose modification time defeats stat
/// comparison, so this is exact without refreshing, and therefore exact
/// against a checkout this process may only read.
private func modifiedPaths(
    repository: FilePath,
    pathspecs: [String]
) throws -> Set<String> {
    let result = try git(
        at: repository,
        arguments: ["diff-files", "--name-only", "-z", "--"] + pathspecs)
    var modified: Set<String> = []
    for record in result.output.split(separator: 0) {
        guard let path = String(data: Data(record), encoding: .utf8) else {
            throw GitSourceCheckoutFailure(
                "Git returned a non-UTF-8 modified path for \(repository)")
        }
        modified.insert(path)
    }
    return modified
}

/// The Git object identity of a file's content.
///
/// Git computes this with collision detection and it is the same value the
/// index records once the content is tracked, which is what keeps a closure
/// identical across committing the content it already covers.
private func gitObjectIdentity(
    repository: FilePath,
    path: FilePath
) throws -> String {
    try git(
        at: repository,
        arguments: ["hash-object", "--", path.string]
    ).textOutput
}

/// The index mode identifying a path, or `nil` when the filesystem must be
/// consulted.
///
/// Git answers for a tracked path that does not differ from its index entry.
/// A deletion is a difference, so a path Git answers for is present, and its
/// recorded mode gives its type and executable bit.
private func gitIdentifiedMode(
    _ entry: TrackedEntry?,
    modified: Set<String>,
    path: String
) -> String? {
    guard let entry, !modified.contains(path) else { return nil }
    switch entry.mode {
    case "100644", "100755", "120000", "160000": return entry.mode
    default: return nil
    }
}

extension String {
    /// The entry kind an index mode denotes.
    fileprivate var gitEntryKind: String {
        switch self {
        case "120000": "symlink"
        case "160000": "nested-checkout"
        default: "file"
        }
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
    // Source capture runs Git once per checkout, and a source closure has
    // hundreds. Waiting for these pipes to close on deallocation leaks four
    // descriptors per invocation, which exhausts a default process limit long
    // before the closure is hashed.
    try? standardOutput.fileHandleForReading.close()
    try? standardError.fileHandleForReading.close()
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
