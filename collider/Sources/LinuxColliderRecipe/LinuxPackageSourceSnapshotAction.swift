import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage

package struct CaptureLinuxPackageSourceSnapshotAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let repositoryRoot: FilePath
        let sourcePaths: [FilePath]
        let output: FilePath
        let sourceAuthority: String?
        let assertedCommit: String?
        let assertedBranch: String?

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: repositoryRoot)
            encoder.appendSequence(sourcePaths) { $0.append(path: $1) }
            encoder.append(path: output)
            encoder.appendOptional(sourceAuthority) { $0.append($1) }
            encoder.appendOptional(assertedCommit) { $0.append($1) }
            encoder.appendOptional(assertedBranch) { $0.append($1) }
        }
    }

    package static let kind: ActionKind = "linux.capture-package-source"

    let repositoryRoot: FilePath
    let sourcePaths: [FilePath]
    let output: FilePath
    let sourceAuthority: String?
    let assertedCommit: String?
    let assertedBranch: String?

    package var identity: Identity {
        Identity(
            repositoryRoot: repositoryRoot,
            sourcePaths: sourcePaths,
            output: output,
            sourceAuthority: sourceAuthority,
            assertedCommit: assertedCommit,
            assertedBranch: assertedBranch)
    }

    package var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "git", executable: .path("/usr/bin/git"), role: .semantic)
            ],
            effects: [
                ActionEffect(.read, scope: .checkout(repositoryRoot)),
                ActionEffect(
                    .readWrite,
                    scope: .output(output.removingLastComponent())),
            ],
            lane: .hostExclusive,
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) async throws {
        let authority: ProductArtifactSourceAuthority
        if let sourceAuthority {
            guard let parsed = ProductArtifactSourceAuthority(rawValue: sourceAuthority)
            else {
                throw LinuxPackageSourceSnapshotFailure(
                    "unknown product source authority: \(sourceAuthority)")
            }
            authority = parsed
        } else {
            authority = .localDevelopment
        }
        let snapshot = try ProductArtifactSourceSnapshot.capture(
            repositoryRoot: repositoryRoot,
            sourceAuthority: authority,
            assertedCommit: assertedCommit,
            assertedBranch: assertedBranch,
            sourcePaths: sourcePaths)
        let candidate = output.removingLastComponent().appending(
            ".\(output.lastComponent!.string).candidate")
        try context.files.createDirectory(output.removingLastComponent())
        try context.files.remove(candidate)
        try context.files.write(try encodedSnapshot(snapshot), to: candidate)
        try context.files.remove(output)
        try context.files.move(from: candidate, to: output)
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        _ = try JSONDecoder().decode(
            ProductArtifactSourceSnapshot.self,
            from: Data(files.read(output)))
    }
}

private func encodedSnapshot(
    _ snapshot: ProductArtifactSourceSnapshot
) throws -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    var bytes = Array(try encoder.encode(snapshot))
    bytes.append(0x0a)
    return bytes
}

private struct LinuxPackageSourceSnapshotFailure: Error,
    CustomStringConvertible, Sendable
{
    let description: String

    init(_ description: String) {
        self.description = "Linux package source snapshot failed: \(description)"
    }
}
