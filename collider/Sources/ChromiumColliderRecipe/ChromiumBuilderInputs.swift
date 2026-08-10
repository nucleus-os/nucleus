import ColliderCore
import Foundation
import SystemPackage

struct ChromiumBuilderInputManifest: Decodable, Hashable, Sendable {
    struct APTRepository: Decodable, Hashable, Sendable {
        let suite: String
        let inReleaseSHA256: String
    }

    let ubuntuSnapshot: String
    let aptRepositories: [APTRepository]

    static func load(from path: FilePath) throws -> Self {
        let data = try Data(contentsOf: URL(filePath: path.string))
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard !manifest.ubuntuSnapshot.isEmpty,
            !manifest.aptRepositories.isEmpty,
            Set(manifest.aptRepositories.map(\.suite)).count
                == manifest.aptRepositories.count,
            manifest.aptRepositories.allSatisfy({
                !$0.suite.isEmpty && ArtifactDigest(sha256Hex: $0.inReleaseSHA256) != nil
            })
        else {
            throw ChromiumBuilderInputFailure.invalidManifest
        }
        return manifest
    }

    func downloads(root: FilePath) throws -> [ChromiumBuilderDownload] {
        try aptRepositories.map { repository in
            ChromiumBuilderDownload(
                specification: try chromiumBuilderDownloadSpec(
                    url: "https://snapshot.ubuntu.com/ubuntu/"
                        + "\(ubuntuSnapshot)/dists/\(repository.suite)/InRelease",
                    sha256: repository.inReleaseSHA256),
                destination: root.appending("releases/\(repository.suite).InRelease"),
                placement: .aptRelease(snapshot: ubuntuSnapshot, suite: repository.suite))
        }
    }
}

struct ChromiumBuilderDownload: Hashable, Sendable {
    enum Placement: Hashable, Sendable {
        case aptRelease(snapshot: String, suite: String)
        case aptIndex
        case aptPackage(String)
    }

    let specification: DownloadSpec
    let destination: FilePath
    let placement: Placement
}

func chromiumBuilderAPTIndexDownloads(
    releases: [ChromiumBuilderDownload],
    root: FilePath,
    files: ActionFileSystem
) throws -> [ChromiumBuilderDownload] {
    try releases.flatMap { download -> [ChromiumBuilderDownload] in
        guard case .aptRelease(let snapshot, let suite) = download.placement else {
            return []
        }
        let contents = String(decoding: try files.read(download.destination), as: UTF8.self)
        let records = try ubuntuSnapshotIndexRecords(contents)
        return try ["main", "universe"].flatMap { component in
            try ["arm64", "amd64"].map { architecture in
                let relativePath = "\(component)/binary-\(architecture)/Packages.gz"
                guard let record = records[relativePath] else {
                    throw ChromiumBuilderInputFailure.invalidPackageIndex
                }
                return ChromiumBuilderDownload(
                    specification: try chromiumBuilderDownloadSpec(
                        url: "https://snapshot.ubuntu.com/ubuntu/\(snapshot)/dists/"
                            + "\(suite)/\(relativePath)",
                        sha256: record.digest,
                        maximumResponseSize: record.size),
                    destination: root.appending(
                        "indexes/\(suite)_\(component)_\(architecture).Packages.gz"),
                    placement: .aptIndex)
            }
        }
    }
}

private func ubuntuSnapshotIndexRecords(
    _ inRelease: String
) throws -> [String: (digest: String, size: Int64)] {
    guard let section = inRelease.range(of: "\nSHA256:\n") else {
        throw ChromiumBuilderInputFailure.invalidPackageIndex
    }
    var records: [String: (digest: String, size: Int64)] = [:]
    for line in inRelease[section.upperBound...].split(separator: "\n") {
        guard line.first == " " else { break }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3,
            let size = Int64(fields[1]),
            size > 0,
            ArtifactDigest(sha256Hex: String(fields[0])) != nil
        else {
            throw ChromiumBuilderInputFailure.invalidPackageIndex
        }
        records[String(fields[2])] = (String(fields[0]), size)
    }
    guard !records.isEmpty else {
        throw ChromiumBuilderInputFailure.invalidPackageIndex
    }
    return records
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
            placement: .aptPackage(digest))
    }
}

private func chromiumBuilderDownloadSpec(
    url urlString: String,
    sha256: String,
    maximumResponseSize: Int64 = .max
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
            "text/plain",
        ],
        requestTimeoutSeconds: 600,
        inactivityTimeoutSeconds: 60,
        maximumRetries: 2,
        resumption: .validatorRequired)
}

enum ChromiumBuilderInputFailure: Error {
    case invalidManifest
    case invalidPackageIndex
    case invalidPackageClosure
}
