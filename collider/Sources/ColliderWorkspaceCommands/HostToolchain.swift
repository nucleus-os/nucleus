import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

/// Host tools that tasks name rather than produce.
///
/// A named tool is resolved from the task environment's PATH and its file digest
/// feeds task identity, so an ambient tool makes cache validity depend on
/// whatever the invoking shell happened to activate. Two accounts execute here
/// and the Actions runner is started by launchd with no shell at all, so the
/// same repository would otherwise resolve different binaries, or none. These
/// are pinned by version and digest, acquired once on the host, and staged in
/// the build store where every account finds the same file.
struct HostToolManifest: Decodable {
    struct Platform: Decodable {
        enum Format: String, Decodable {
            case tar
            case zip
        }

        let url: String
        let sha256: String
        let format: Format
        let binaryDirectory: String
        let executables: [String]
        /// Declared rather than inferred: the download refuses a response whose
        /// type was not expected, and an origin it was not told to follow.
        let mediaTypes: [String]
        let redirectOrigins: [String]
    }

    struct Tool: Decodable {
        let name: String
        let version: String
        let platforms: [String: Platform]
    }

    let tools: [Tool]

    static let relativePath = "tools/host-tools.json"

    /// The single supported host today. A second one adds a key here rather
    /// than a second resolution mechanism.
    static var platformKey: String {
        #if arch(arm64)
        "macos-arm64"
        #else
        "macos-x86_64"
        #endif
    }

    static func load(root: FilePath) throws -> HostToolManifest {
        try JSONDecoder().decode(
            HostToolManifest.self,
            from: Data(
                contentsOf: URL(fileURLWithPath: root.appending(relativePath).string)))
    }
}

struct HostToolchain {
    let manifest: HostToolManifest
    let cacheRoot: FilePath

    init(manifest: HostToolManifest, cacheRoot: FilePath) {
        self.manifest = manifest
        self.cacheRoot = cacheRoot
    }

    private var root: FilePath { cacheRoot.appending("host-tools") }

    private func stagedRoot(_ tool: HostToolManifest.Tool) -> FilePath {
        root.appending("\(tool.name)/\(tool.version)")
    }

    /// Where each pinned tool's executables live once staged. Deriving this
    /// requires no filesystem access, so the task environment can name it
    /// before anything has been acquired.
    var binaryDirectories: [FilePath] {
        manifest.tools.compactMap { tool in
            guard let platform = tool.platforms[HostToolManifest.platformKey] else {
                return nil
            }
            return stagedRoot(tool).appending(platform.binaryDirectory)
        }
    }

    /// Acquires anything absent. Present tools cost one existence check each,
    /// so this runs before planning without making every invocation pay.
    func stage(context: WorkspaceContext) async throws {
        for tool in manifest.tools {
            guard let platform = tool.platforms[HostToolManifest.platformKey] else {
                throw WorkspaceFailure.message(
                    "host tool '\(tool.name)' declares no \(HostToolManifest.platformKey) build")
            }
            let destination = stagedRoot(tool)
            let binary = destination.appending(platform.binaryDirectory)
                .appending(platform.executables[0])
            if FileManager.default.isExecutableFile(atPath: binary.string) { continue }
            try await acquire(tool, platform: platform, into: destination, context: context)
            guard FileManager.default.isExecutableFile(atPath: binary.string) else {
                throw WorkspaceFailure.message(
                    "host tool '\(tool.name)' did not stage an executable at \(binary)")
            }
        }
    }

    private func acquire(
        _ tool: HostToolManifest.Tool,
        platform: HostToolManifest.Platform,
        into destination: FilePath,
        context: WorkspaceContext
    ) async throws {
        guard let url = URL(string: platform.url),
            let digest = ArtifactDigest(sha256Hex: platform.sha256)
        else {
            throw WorkspaceFailure.message(
                "host tool '\(tool.name)' declares an invalid download")
        }
        try await context.hostPhases.withPhase(
            "acquiring host tool \(tool.name) \(tool.version)"
        ) {
            let downloads = cacheRoot.appending("downloads/host-tools")
            try FileManager.default.createDirectory(
                atPath: downloads.string, withIntermediateDirectories: true)
            let archive = downloads.appending(
                "\(tool.name)-\(tool.version)-\(url.lastPathComponent)")
            try await context.runtime.download(
                DownloadSpec(
                    url: url,
                    permittedRedirectOrigins: Set(platform.redirectOrigins),
                    expectedDigest: digest,
                    maximumResponseSize: 512 * 1_024 * 1_024,
                    acceptedMediaTypes: Set(platform.mediaTypes),
                    requestTimeoutSeconds: 120,
                    inactivityTimeoutSeconds: 120,
                    maximumRedirects: 5,
                    maximumRetries: 3,
                    resumption: .validatorRequired),
                to: archive)
            // Extract beside the destination and move into place, so an
            // interrupted acquisition never leaves a partial tool that the
            // presence check above would accept.
            let staging = FilePath(destination.string + ".staging")
            try? FileManager.default.removeItem(atPath: staging.string)
            try FileManager.default.createDirectory(
                atPath: staging.string, withIntermediateDirectories: true)
            switch platform.format {
            case .tar:
                try await context.run(
                    "/usr/bin/tar", ["-xf", archive.string, "-C", staging.string])
            case .zip:
                try await context.run(
                    "/usr/bin/unzip", ["-q", archive.string, "-d", staging.string])
            }
            try FileManager.default.createDirectory(
                atPath: destination.removingLastComponent().string,
                withIntermediateDirectories: true)
            try? FileManager.default.removeItem(atPath: destination.string)
            try FileManager.default.moveItem(
                atPath: staging.string, toPath: destination.string)
        }
    }
}

/// Acquires the pinned host tools a plan will resolve, so the tool set is a
/// property of the repository rather than of the environment that started the
/// build. Absent a manifest, the host resolves tools as it always did.
package func stageHostToolchain(in context: WorkspaceContext) async throws {
    guard let manifest = try? HostToolManifest.load(root: context.root) else { return }
    try await HostToolchain(manifest: manifest, cacheRoot: context.cacheRoot)
        .stage(context: context)
}
