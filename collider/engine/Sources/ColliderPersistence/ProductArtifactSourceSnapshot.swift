import ColliderCore
import Foundation
import SystemPackage

public struct ProductArtifactSourceSnapshot: Codable, Equatable, Sendable {
    public let closure: ArtifactDigest
    public let submoduleClosures: [ProductArtifactSourceClosure]
    public let provenance: ProductArtifactProvenance

    public init(
        closure: ArtifactDigest,
        submoduleClosures: [ProductArtifactSourceClosure],
        provenance: ProductArtifactProvenance
    ) {
        self.closure = closure
        self.submoduleClosures = submoduleClosures
        self.provenance = provenance
    }

    public static func capture(
        repositoryRoot: FilePath,
        sourceAuthority: ProductArtifactSourceAuthority,
        assertedCommit: String? = nil,
        assertedBranch: String? = nil,
        sourcePaths: [FilePath]? = nil,
        observe: SourceCaptureObserver? = nil
    ) throws -> Self {
        let sourcePaths = sourcePaths ?? [repositoryRoot]
        guard !sourcePaths.isEmpty else {
            throw ProductArtifactStoreFailure("product source closure is empty")
        }
        let scopes = try sourcePaths.map { path -> String in
            guard let relative = path.relativeSubpath(from: repositoryRoot) else {
                throw ProductArtifactStoreFailure(
                    "product source path is outside the repository: \(path)")
            }
            return relative.string
        }
        let closure = try sourceDigest(sourcePaths, observe: observe)
        let submodules = try submodulePaths(repositoryRoot).filter { relative in
            scopes.contains {
                sourcePath(relative, isWithin: $0)
                    || sourcePath($0, isWithin: relative)
            }
        }.map { relative in
            ProductArtifactSourceClosure(
                relativePath: relative,
                digest: try sourceDigest(
                    repositoryRoot.appending(relative), observe: observe))
        }
        let head = try gitText(
            at: repositoryRoot,
            arguments: ["rev-parse", "HEAD"])
        if sourceAuthority == .protectedMain {
            guard let assertedCommit, isFullGitCommit(assertedCommit) else {
                throw ProductArtifactStoreFailure(
                    "protected-main source requires an exact 40-character commit")
            }
            guard assertedBranch == "refs/heads/main" else {
                throw ProductArtifactStoreFailure(
                    "protected-main source requires refs/heads/main")
            }
        }
        let checkoutBranch = try gitText(
            at: repositoryRoot,
            arguments: ["symbolic-ref", "-q", "HEAD"],
            permitsNoMatch: true)
        if let assertedCommit, assertedCommit != head {
            throw ProductArtifactStoreFailure(
                "asserted source commit does not match the checked-out HEAD")
        }
        if let assertedBranch, assertedBranch != checkoutBranch,
            sourceAuthority != .protectedMain
        {
            throw ProductArtifactStoreFailure(
                "asserted source branch does not match the checked-out branch")
        }
        let provenanceScopes =
            sourceAuthority == .protectedMain ? [""] : scopes
        let changed = try gitPaths(
            at: repositoryRoot,
            arguments: ["diff", "--name-only", "-z", "HEAD", "--"]
        ).filter { path in
            provenanceScopes.contains { sourcePath(path, isWithin: $0) }
        }
        let untracked = try gitPaths(
            at: repositoryRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"]
        ).filter { path in
            provenanceScopes.contains { sourcePath(path, isWithin: $0) }
        }
        return try Self(
            closure: closure,
            submoduleClosures: submodules,
            provenance: ProductArtifactProvenance(
                baseCommit: assertedCommit ?? head,
                branch: assertedBranch ?? checkoutBranch,
                dirtyPaths: Array(Set(changed).union(untracked)).sorted(),
                sourceAuthority: sourceAuthority))
    }
}

private func isFullGitCommit(_ value: String) -> Bool {
    value.count == 40
        && value.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 97...102: true
            default: false
            }
        }
}

private func sourceDigest(
    _ checkouts: [FilePath],
    observe: SourceCaptureObserver? = nil
) throws -> ArtifactDigest {
    try GitSourceCheckoutHasher.digest(
        checkouts,
        digestFile: { path, _ in try ArtifactHasher.digest(file: path) },
        digestNestedCheckout: { try sourceDigest($0, observe: observe) },
        observe: observe)
}

private func sourceDigest(
    _ checkout: FilePath,
    observe: SourceCaptureObserver? = nil
) throws -> ArtifactDigest {
    try GitSourceCheckoutHasher.digest(
        checkout,
        digestFile: { path, _ in try ArtifactHasher.digest(file: path) },
        digestNestedCheckout: { try sourceDigest($0, observe: observe) },
        observe: observe)
}

private func sourcePath(_ candidate: String, isWithin scope: String) -> Bool {
    scope.isEmpty || candidate == scope || candidate.hasPrefix(scope + "/")
}

private func submodulePaths(_ repositoryRoot: FilePath) throws -> [String] {
    guard repositoryRoot.appending(".gitmodules").exists() else { return [] }
    let output =
        try gitText(
            at: repositoryRoot,
            arguments: [
                "config", "--file", ".gitmodules", "--get-regexp", "path",
            ],
            permitsNoMatch: true) ?? ""
    return try output.split(separator: "\n").map { line in
        guard let separator = line.firstIndex(of: " ") else {
            throw ProductArtifactStoreFailure(
                "Git returned malformed submodule configuration")
        }
        return String(line[line.index(after: separator)...])
    }.sorted()
}

private func gitPaths(
    at repositoryRoot: FilePath,
    arguments: [String]
) throws -> [String] {
    try runGit(at: repositoryRoot, arguments: arguments).output
        .split(separator: 0)
        .map { record in
            guard let path = String(data: Data(record), encoding: .utf8) else {
                throw ProductArtifactStoreFailure(
                    "Git returned a non-UTF-8 source path")
            }
            return path
        }
}

private func gitText(
    at repositoryRoot: FilePath,
    arguments: [String],
    permitsNoMatch: Bool = false
) throws -> String? {
    let result = try runGit(
        at: repositoryRoot,
        arguments: arguments,
        permitsNoMatch: permitsNoMatch)
    guard result.status == 0 else { return nil }
    return String(decoding: result.output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct SourceGitResult {
    let status: Int32
    let output: Data
}

private func runGit(
    at repositoryRoot: FilePath,
    arguments: [String],
    permitsNoMatch: Bool = false
) throws -> SourceGitResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = URL(fileURLWithPath: repositoryRoot.string)
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
        throw ProductArtifactStoreFailure(
            "could not execute Git for source provenance: \(error)")
    }
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0
        && !(permitsNoMatch && process.terminationStatus == 1)
    {
        let message = String(decoding: errorOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw ProductArtifactStoreFailure(
            "Git failed while reading source provenance: \(message)")
    }
    return SourceGitResult(status: process.terminationStatus, output: output)
}

extension FilePath {
    fileprivate func exists() -> Bool {
        (try? stat(followTargetSymlink: false)) != nil
    }
}
