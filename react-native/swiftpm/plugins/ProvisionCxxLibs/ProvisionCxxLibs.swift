import Foundation
import PackagePlugin

private let archives = ["libNucleusReactRuntimeHostCxx.a"]

private enum ProvisionFailure: Error, CustomStringConvertible {
    case usage
    case noProductDirectory(configuration: String)
    case ambiguousProductDirectories(configuration: String, paths: [String])
    case missingArchive(configuration: String, path: String)

    var description: String {
        switch self {
        case .usage:
            "usage: swift package provision-cxx-libs <debug|release> "
                + "--allow-writing-to-package-directory"
        case .noProductDirectory(let configuration):
            "no (configuration) product directory contains every required host archive; "
                + "build the NucleusReactRuntimeHostCxx product first"
        case .ambiguousProductDirectories(let configuration, let paths):
            "multiple (configuration) product directories contain the required archives: "
                + paths.joined(separator: ", ")
        case .missingArchive(let configuration, let path):
            "required (configuration) host archive is missing: \(path)"
        }
    }
}

private struct ArchiveMetadata: Codable {
    let schemaVersion: Int
    let configuration: String
    let productDirectory: String
    let archive: String
    let byteCount: UInt64
    let fingerprint: String
}

@main
struct ProvisionCxxLibs: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let pluginArguments = arguments.filter {
            $0 != "--allow-writing-to-package-directory"
        }
        guard pluginArguments.count == 1,
              let configuration = Configuration(
                rawValue: pluginArguments[0].lowercased())
        else {
            Diagnostics.error(ProvisionFailure.usage.description)
            throw ProvisionFailure.usage
        }

        let fileManager = FileManager.default
        let root = context.package.directoryURL
        let productsRoot = root.appendingPathComponent(".build/out/Products", isDirectory: true)
        let productDirectory = try locateProductDirectory(
            configuration: configuration,
            productsRoot: productsRoot,
            fileManager: fileManager)
        let outputDirectory = root
            .appendingPathComponent(".cxx-build", isDirectory: true)
            .appendingPathComponent(configuration.rawValue, isDirectory: true)
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true)

        for archive in archives {
            let source = productDirectory.appendingPathComponent(archive)
            guard fileManager.fileExists(atPath: source.path) else {
                let failure = ProvisionFailure.missingArchive(
                    configuration: configuration.rawValue,
                    path: source.path)
                Diagnostics.error(failure.description)
                throw failure
            }

            let destination = outputDirectory.appendingPathComponent(archive)
            let temporary = outputDirectory.appendingPathComponent(".\(archive).staging")
            try? fileManager.removeItem(at: temporary)
            try fileManager.copyItem(at: source, to: temporary)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)

            let byteCount = try fileSize(destination)
            let fingerprint = try fnv1a64(destination)
            let metadata = ArchiveMetadata(
                schemaVersion: 1,
                configuration: configuration.rawValue,
                productDirectory: productDirectory.lastPathComponent,
                archive: archive,
                byteCount: byteCount,
                fingerprint: fingerprint)
            let metadataURL = outputDirectory.appendingPathComponent("\(archive).metadata.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

            print(
                "provision-cxx-libs: staged \(archive) "
                    + "(\(configuration.rawValue), \(byteCount) bytes, \(fingerprint)) "
                    + "-> .cxx-build/\(configuration.rawValue)/")
        }
    }

    private enum Configuration: String {
        case debug
        case release

        var productPrefix: String {
            rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    private func locateProductDirectory(
        configuration: Configuration,
        productsRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        let candidates = try fileManager.contentsOfDirectory(
            at: productsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
            .filter { candidate in
                candidate.lastPathComponent.hasPrefix(configuration.productPrefix + "-")
                    && archives.allSatisfy {
                        fileManager.fileExists(
                            atPath: candidate.appendingPathComponent($0).path)
                    }
            }
        guard !candidates.isEmpty else {
            let failure = ProvisionFailure.noProductDirectory(
                configuration: configuration.rawValue)
            Diagnostics.error(failure.description)
            throw failure
        }
        guard candidates.count == 1 else {
            let failure = ProvisionFailure.ambiguousProductDirectories(
                configuration: configuration.rawValue,
                paths: candidates.map(\.path).sorted())
            Diagnostics.error(failure.description)
            throw failure
        }
        return candidates[0]
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw ProvisionFailure.missingArchive(
                configuration: "unknown", path: url.path)
        }
        return number.uint64Value
    }

    private func fnv1a64(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash: UInt64 = 0xcbf29ce484222325
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
        }
        return String(format: "%016llx", hash)
    }
}
