import ColliderCore
import Foundation
import SystemPackage

struct NativeBuilderInputManifest: Decodable, Hashable, Sendable {
    struct Archive: Decodable, Hashable, Sendable {
        let name: String
        let url: String
        let sha256: String
        let maximumResponseSize: Int64
    }

    struct APTIndex: Decodable, Hashable, Sendable {
        let name: String
        let url: String
        let sha256: String
        let size: Int64
    }

    let ubuntuSnapshot: String
    let archives: [Archive]
    let aptIndexes: [APTIndex]

    static func load(from path: FilePath) throws -> Self {
        let data = try Data(contentsOf: URL(filePath: path.string))
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard !manifest.ubuntuSnapshot.isEmpty,
            !manifest.archives.isEmpty,
            !manifest.aptIndexes.isEmpty,
            Set(manifest.archives.map(\.name)).count == manifest.archives.count,
            Set(manifest.aptIndexes.map(\.name)).count == manifest.aptIndexes.count
        else {
            throw NativeBuilderInputFailure.invalidManifest
        }
        return manifest
    }
}

struct NativeBuilderDownload: Hashable, Sendable {
    enum Placement: Hashable, Sendable {
        case archive(String)
        case aptIndex(String)
        case aptPackage(role: String, digest: String)
    }

    let identity: DownloadActionIdentity
    let placement: Placement
}

extension NativeBuilderInputManifest {
    func downloads(root: FilePath) throws -> [NativeBuilderDownload] {
        try archives.map { archive in
            NativeBuilderDownload(
                identity: DownloadActionIdentity(
                    specification: try nativeBuilderDownloadSpec(
                        url: archive.url,
                        sha256: archive.sha256,
                        maximumResponseSize: archive.maximumResponseSize),
                    destination: root.appending(archive.name)),
                placement: .archive(archive.name))
        }
            + aptIndexes.map { index in
                NativeBuilderDownload(
                    identity: DownloadActionIdentity(
                        specification: try nativeBuilderDownloadSpec(
                            url: index.url,
                            sha256: index.sha256,
                            maximumResponseSize: index.size),
                        destination: root.appending("indexes/\(index.name)")),
                    placement: .aptIndex(index.name))
            }
    }
}

func nativeBuilderPackageDownloads(
    manifest: String,
    root: FilePath
) throws -> [NativeBuilderDownload] {
    try manifest.split(whereSeparator: \.isNewline).map { line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4,
            fields[0] == "install" || fields[0] == "extract",
            let size = Int64(fields[2]),
            size > 0
        else {
            throw NativeBuilderInputFailure.invalidPackageClosure
        }
        let role = String(fields[0])
        let sha256 = String(fields[3])
        return NativeBuilderDownload(
            identity: DownloadActionIdentity(
                specification: try nativeBuilderDownloadSpec(
                    url: String(fields[1]),
                    sha256: sha256,
                    maximumResponseSize: size),
                destination: root.appending("packages/\(sha256).deb")),
            placement: .aptPackage(role: role, digest: sha256))
    }
}

private func nativeBuilderDownloadSpec(
    url urlString: String,
    sha256: String,
    maximumResponseSize: Int64
) throws -> DownloadSpec {
    guard let url = URL(string: urlString),
        let digest = ArtifactDigest(sha256Hex: sha256)
    else {
        throw NativeBuilderInputFailure.invalidManifest
    }
    return try DownloadSpec(
        url: url,
        permittedRedirectOrigins: [
            "https://codeload.github.com",
            "https://dl.google.com",
            "https://download.swift.org",
            "https://github.com",
            "https://nodejs.org",
            "https://release-assets.githubusercontent.com",
            "https://snapshot.ubuntu.com",
        ],
        expectedDigest: digest,
        maximumResponseSize: maximumResponseSize,
        acceptedMediaTypes: [
            "application/gzip",
            "application/octet-stream",
            "application/vnd.debian.binary-package",
            "application/x-debian-package",
            "application/x-gzip",
            "application/x-xz",
            "application/x-zip-compressed",
            "application/zip",
        ],
        requestTimeoutSeconds: 600,
        inactivityTimeoutSeconds: 60,
        maximumRetries: 2,
        resumption: .validatorRequired)
}

enum NativeBuilderInputFailure: Error {
    case invalidManifest
    case invalidPackageClosure
}
