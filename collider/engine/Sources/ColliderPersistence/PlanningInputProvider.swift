import ColliderCore
import Foundation
import SystemPackage

/// Read-only planning services with planning-local memoization. The provider is
/// confined to one synchronous planning operation; only its durable digest
/// metadata index is published after a complete plan is produced.
package final class PlanningInputProvider: @unchecked Sendable {
    private let digests: PlanningArtifactDigestCache
    private var tools: [String: ToolIdentitySnapshot] = [:]

    package init(digestIndex: FilePath) {
        digests = PlanningArtifactDigestCache(persistentFile: digestIndex)
    }

    package var hashingDurationNanoseconds: UInt64 {
        digests.hashingDurationNanoseconds
    }

    package func digest(bytes: [UInt8]) -> ArtifactDigest {
        ArtifactHasher.digest(bytes: bytes)
    }

    package func digest(file path: FilePath) throws -> ArtifactDigest {
        try digests.digest(file: path)
    }

    package func digest(tree path: FilePath) throws -> ArtifactDigest {
        try digests.digest(tree: path)
    }

    package func digest(artifact reference: ArtifactReference) throws -> ArtifactDigest {
        let path = reference.path
        let metadata = try path.stat(followTargetSymlink: reference.validation != .symlink)
        var encoder = IdentityEncoder()
        encoder.append(metadata.permissions.contains(.ownerExecute))
        switch metadata.type {
        case .regular:
            encoder.append("file")
            encoder.append(digest: try digest(file: path))
        case .directory:
            encoder.append("directory")
            encoder.append(digest: try digest(tree: path))
        case .symbolicLink:
            encoder.append("symlink")
            encoder.append(try FileManager.default.destinationOfSymbolicLink(atPath: path.string))
        default:
            throw PersistenceFailure.invalidPath("unsupported artifact content at \(path)")
        }
        return .sha256(encoder.bytes)
    }

    package func digest(sourceCheckout path: FilePath) async throws -> ArtifactDigest {
        try await digests.digest(sourceCheckout: path)
    }

    package func digest(
        sourceCheckoutClosure paths: [FilePath]
    ) async throws -> ArtifactDigest {
        try await digests.digest(sourceCheckoutClosure: paths)
    }

    /// Every source closure planning read, and the identity each had when it
    /// was read. This is what a run revalidates against.
    package var plannedSourceClosures: [PlannedSourceClosure] {
        digests.plannedSourceClosures
    }

    package func semanticToolIdentity(
        _ executable: CommandSpec.Executable,
        environment: [String: String]
    ) throws -> ToolIdentitySnapshot {
        let cacheKey =
            String(describing: executable) + "\u{0}" + (environment["PATH"] ?? "")
        if let cached = tools[cacheKey] {
            return cached
        }
        let path: FilePath
        switch executable {
        case .path(let value):
            path = value
        case .artifact(let reference):
            throw PersistenceFailure.invalidPlanningTool(
                "typed task-produced executable is identified by its producer: "
                    + "\(reference.path)")
        case .taskOutput(let value):
            throw PersistenceFailure.invalidPlanningTool(
                "task-produced executable cannot be declared as an external tool: \(value)")
        case .operationalNamed(let name):
            throw PersistenceFailure.invalidPlanningTool(
                "operational executable cannot be declared as a semantic tool: \(name)")
        case .named(let name):
            guard let resolved = resolveExecutable(name, path: environment["PATH"]) else {
                throw PersistenceFailure.toolNotFound(name)
            }
            path = FilePath(
                URL(fileURLWithPath: resolved.string).resolvingSymlinksInPath().path)
        }
        let snapshot = ToolIdentitySnapshot(
            path: path,
            digest: try digests.digest(file: path))
        tools[cacheKey] = snapshot
        return snapshot
    }

    package func persistDigestIndex() throws {
        try digests.persist()
    }
}

private func resolveExecutable(_ name: String, path: String?) -> FilePath? {
    guard let path else { return nil }
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let candidate = FilePath(String(directory)).appending(name)
        if FileManager.default.isExecutableFile(atPath: candidate.string) {
            return candidate
        }
    }
    return nil
}
