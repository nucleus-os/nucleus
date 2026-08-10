import ColliderCore
import Foundation
import SystemPackage

struct ChromiumBuilderInputManifest: Decodable, Hashable, Sendable {
    struct APTIndex: Decodable, Hashable, Sendable {
        let name: String
        let url: String
        let sha256: String
        let size: Int64
    }

    let ubuntuSnapshot: String
    let aptIndexes: [APTIndex]

    static func load(from path: FilePath) throws -> Self {
        let data = try Data(contentsOf: URL(filePath: path.string))
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.ubuntuSnapshot == "20260730T000000Z",
            !manifest.aptIndexes.isEmpty,
            Set(manifest.aptIndexes.map(\.name)).count == manifest.aptIndexes.count
        else {
            throw ChromiumBuilderInputFailure.invalidManifest
        }
        return manifest
    }

    func downloads(root: FilePath) throws -> [ChromiumBuilderDownload] {
        try aptIndexes.map { index in
            ChromiumBuilderDownload(
                specification: try chromiumBuilderDownloadSpec(
                    url: index.url,
                    sha256: index.sha256,
                    maximumResponseSize: index.size),
                destination: root.appending("indexes/\(index.name)"),
                digest: nil)
        }
    }
}

struct ChromiumBuilderDownload: Hashable, Sendable {
    let specification: DownloadSpec
    let destination: FilePath
    let digest: String?
}

func chromiumBuilderPackageDownloads(
    manifest: String,
    root: FilePath
) throws -> [ChromiumBuilderDownload] {
    try manifest.split(whereSeparator: \.isNewline).map { line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4,
            fields[0] == "install",
            let size = Int64(fields[2]),
            size > 0
        else {
            throw ChromiumBuilderInputFailure.invalidPackageClosure
        }
        let digest = String(fields[3])
        return ChromiumBuilderDownload(
            specification: try chromiumBuilderDownloadSpec(
                url: String(fields[1]),
                sha256: digest,
                maximumResponseSize: size),
            destination: root.appending("packages/\(digest).deb"),
            digest: digest)
    }
}

private func chromiumBuilderDownloadSpec(
    url urlString: String,
    sha256: String,
    maximumResponseSize: Int64
) throws -> DownloadSpec {
    guard let url = URL(string: urlString),
        let digest = ArtifactDigest(sha256Hex: sha256)
    else {
        throw ChromiumBuilderInputFailure.invalidManifest
    }
    return try DownloadSpec(
        url: url,
        permittedRedirectOrigins: ["https://snapshot.ubuntu.com"],
        expectedDigest: digest,
        maximumResponseSize: maximumResponseSize,
        acceptedMediaTypes: [
            "application/gzip",
            "application/octet-stream",
            "application/vnd.debian.binary-package",
            "application/x-debian-package",
            "application/x-gzip",
        ],
        requestTimeoutSeconds: 600,
        inactivityTimeoutSeconds: 60,
        maximumRetries: 2,
        resumption: .validatorRequired)
}

enum ChromiumBuilderInputFailure: Error {
    case invalidManifest
    case invalidPackageClosure
}
