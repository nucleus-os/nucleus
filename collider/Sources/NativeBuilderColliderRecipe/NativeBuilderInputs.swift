import ColliderCore
import Foundation
import SystemPackage

struct NativeBuilderInputManifest: Decodable, Hashable, Sendable {
    struct Archive: Decodable, Hashable, Sendable {
        let name: String
        let url: String
        let sha256: String
    }

    struct APTRepository: Decodable, Hashable, Sendable {
        let suite: String
        let inReleaseSHA256: String
    }

    let ubuntuSnapshot: String
    let archives: [Archive]
    let aptRepositories: [APTRepository]

    static func load(from path: FilePath) throws -> Self {
        let data = try Data(contentsOf: URL(filePath: path.string))
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard !manifest.ubuntuSnapshot.isEmpty,
            !manifest.archives.isEmpty,
            !manifest.aptRepositories.isEmpty,
            Set(manifest.archives.map(\.name)).count == manifest.archives.count,
            Set(manifest.aptRepositories.map(\.suite)).count
                == manifest.aptRepositories.count,
            manifest.aptRepositories.allSatisfy({
                !$0.suite.isEmpty && ArtifactDigest(sha256Hex: $0.inReleaseSHA256) != nil
            })
        else {
            throw NativeBuilderInputFailure.invalidManifest
        }
        return manifest
    }
}

struct NativeBuilderDownload: Hashable, Sendable {
    enum Placement: Hashable, Sendable {
        case archive(String)
        case aptRelease(snapshot: String, suite: String)
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
                        sha256: archive.sha256),
                    destination: root.appending(archive.name)),
                placement: .archive(archive.name))
        }
            + aptRepositories.map { repository in
                NativeBuilderDownload(
                    identity: DownloadActionIdentity(
                        specification: try nativeBuilderDownloadSpec(
                            url: "https://snapshot.ubuntu.com/ubuntu/"
                                + "\(ubuntuSnapshot)/dists/\(repository.suite)/InRelease",
                            sha256: repository.inReleaseSHA256),
                        destination: root.appending(
                            "releases/\(repository.suite).InRelease")),
                    placement: .aptRelease(
                        snapshot: ubuntuSnapshot,
                        suite: repository.suite))
            }
    }
}

func nativeBuilderAPTIndexDownloads(
    releases: [NativeBuilderDownload],
    root: FilePath,
    files: ActionFileSystem
) throws -> [NativeBuilderDownload] {
    try releases.flatMap { download -> [NativeBuilderDownload] in
        guard case .aptRelease(let snapshot, let suite) = download.placement else {
            return []
        }
        let contents = String(
            decoding: try files.read(download.identity.destination),
            as: UTF8.self)
        let records = try ubuntuSnapshotIndexRecords(contents)
        return try ["main", "universe"].flatMap { component in
            try ["arm64", "amd64"].map { architecture in
                let relativePath =
                    "\(component)/binary-\(architecture)/Packages.gz"
                guard let record = records[relativePath] else {
                    throw NativeBuilderInputFailure.invalidPackageIndex
                }
                let name = "\(suite)_\(component)_\(architecture).Packages.gz"
                return NativeBuilderDownload(
                    identity: DownloadActionIdentity(
                        specification: try nativeBuilderDownloadSpec(
                            url: "https://snapshot.ubuntu.com/ubuntu/\(snapshot)/dists/"
                                + "\(suite)/\(relativePath)",
                            sha256: record.digest,
                            maximumResponseSize: record.size),
                        destination: root.appending("indexes/\(name)")),
                    placement: .aptIndex(name))
            }
        }
    }
}

private func ubuntuSnapshotIndexRecords(
    _ inRelease: String
) throws -> [String: (digest: String, size: Int64)] {
    guard let section = inRelease.range(of: "\nSHA256:\n") else {
        throw NativeBuilderInputFailure.invalidPackageIndex
    }
    var records: [String: (digest: String, size: Int64)] = [:]
    for line in inRelease[section.upperBound...].split(separator: "\n") {
        guard line.first == " " else { break }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3,
            let size = Int64(fields[1]),
            size >= 0,
            ArtifactDigest(sha256Hex: String(fields[0])) != nil
        else {
            throw NativeBuilderInputFailure.invalidPackageIndex
        }
        records[String(fields[2])] = (String(fields[0]), size)
    }
    guard !records.isEmpty else {
        throw NativeBuilderInputFailure.invalidPackageIndex
    }
    return records
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
    maximumResponseSize: Int64 = .max
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
            "text/plain",
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
    case invalidPackageIndex
    case invalidPackageClosure
}
