import ColliderCore
import Foundation
import SystemPackage

struct LavapipeTestArtifact: Equatable {
    let sourceManifest: FilePath
    let library: FilePath
    let stagedManifest: FilePath
    let stagedBytes: [UInt8]

    static func resolve(context: WorkspaceContext) throws -> Self {
        let fileManager = FileManager.default
        let candidates: [String] =
            [context.environment["NUCLEUS_LAVAPIPE_ICD"]].compactMap { $0 }
            + [
                "/usr/share/vulkan/icd.d/lvp_icd.json",
                "/usr/local/share/vulkan/icd.d/lvp_icd.json",
            ]
        guard let manifestPath = candidates.first(where: {
            fileManager.isReadableFile(atPath: $0)
        }) else {
            throw WorkspaceFailure.message(
                "Mesa lavapipe ICD manifest is missing; install lavapipe or set "
                    + "NUCLEUS_LAVAPIPE_ICD to its JSON manifest")
        }
        let sourceManifest = FilePath(manifestPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let decoded = try JSONDecoder().decode(VulkanICDManifest.self, from: data)
        guard decoded.ICD.libraryPath.lowercased().contains("lvp")
                || decoded.ICD.libraryPath.lowercased().contains("lavapipe")
        else {
            throw WorkspaceFailure.message(
                "\(manifestPath) is not a Mesa lavapipe ICD manifest")
        }
        let library = try resolveICDLibrary(
            decoded.ICD.libraryPath,
            manifest: sourceManifest,
            environment: context.environment)
        let staged = FilePath(
            context.cacheRoot.appendingPathComponent(
                "nucleus/test-vulkan/lavapipe_icd.json").path)
        let stagedManifest = VulkanICDManifest(
            fileFormatVersion: decoded.fileFormatVersion,
            ICD: .init(
                apiVersion: decoded.ICD.apiVersion,
                libraryPath: library.string))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var bytes = Array(try encoder.encode(stagedManifest))
        bytes.append(UInt8(ascii: "\n"))
        return Self(
            sourceManifest: sourceManifest,
            library: library,
            stagedManifest: staged,
            stagedBytes: bytes)
    }

    var task: TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "workspace.lavapipe-icd"),
            component: ComponentID(rawValue: "compositor"),
            inputs: [
                .file(sourceManifest),
                .file(library),
                .value(name: "staged-manifest", bytes: stagedBytes),
            ],
            outputs: [
                OutputDeclaration(
                    path: stagedManifest,
                    validation: .regularFile),
            ],
            locks: [.shared(stagedManifest
                .removingLastComponent()
                .removingLastComponent()
                .appending("locks/lavapipe-icd.lock"))],
            operation: .sequence([
                .createDirectory(stagedManifest.removingLastComponent()),
                .writeFile(stagedManifest, bytes: stagedBytes),
            ]))
    }
}

func requiredDRMRenderNode(environment: [String: String]) throws -> String {
    let fileManager = FileManager.default
    let candidates: [String]
    if let explicit = environment["NUCLEUS_TEST_DRM_RENDER_NODE"],
       !explicit.isEmpty
    {
        candidates = [explicit]
    } else {
        candidates = (
            try? fileManager.contentsOfDirectory(atPath: "/dev/dri")
        )?.filter { $0.hasPrefix("renderD") }
            .sorted()
            .map { "/dev/dri/\($0)" } ?? []
    }
    guard let path = candidates.first(where: {
        guard fileManager.isReadableFile(atPath: $0),
              fileManager.isWritableFile(atPath: $0),
              let attributes = try? fileManager.attributesOfItem(atPath: $0),
              attributes[.type] as? FileAttributeType == .typeCharacterSpecial
        else { return false }
        return true
    }) else {
        throw WorkspaceFailure.message(
            "gpu-drm requires a readable and writable /dev/dri/renderD* node; "
                + "set NUCLEUS_TEST_DRM_RENDER_NODE to the required node")
    }
    return path
}

private struct VulkanICDManifest: Codable {
    struct ICDRecord: Codable {
        let apiVersion: String
        let libraryPath: String

        enum CodingKeys: String, CodingKey {
            case apiVersion = "api_version"
            case libraryPath = "library_path"
        }
    }

    let fileFormatVersion: String
    let ICD: ICDRecord

    enum CodingKeys: String, CodingKey {
        case fileFormatVersion = "file_format_version"
        case ICD
    }
}

private func resolveICDLibrary(
    _ configuredPath: String,
    manifest: FilePath,
    environment: [String: String]
) throws -> FilePath {
    let fileManager = FileManager.default
    if configuredPath.first == "/",
       fileManager.isReadableFile(atPath: configuredPath)
    {
        return FilePath(configuredPath)
    }

    #if arch(x86_64)
    let multiarch = "x86_64-linux-gnu"
    #elseif arch(arm64)
    let multiarch = "aarch64-linux-gnu"
    #else
    let multiarch = ""
    #endif
    let environmentDirectories = (environment["LD_LIBRARY_PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
    let standardDirectories = [
        manifest.removingLastComponent().string,
        "/usr/lib/\(multiarch)",
        "/lib/\(multiarch)",
        "/usr/local/lib",
        "/usr/lib64",
        "/usr/lib",
        "/lib64",
        "/lib",
    ]
    for directory in environmentDirectories + standardDirectories {
        let candidate = URL(
            fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(configuredPath).standardizedFileURL.path
        if fileManager.isReadableFile(atPath: candidate) {
            return FilePath(candidate)
        }
    }
    throw WorkspaceFailure.message(
        "lavapipe ICD library '\(configuredPath)' from \(manifest) is missing")
}
