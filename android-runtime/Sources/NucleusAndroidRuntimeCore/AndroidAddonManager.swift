#if os(Linux)
import Foundation
import Glibc

public enum AndroidAddonManagementFailure:
    Error,
    CustomStringConvertible,
    Sendable
{
    case message(String)
    case process(executable: String, status: Int32, error: String)

    public var description: String {
        switch self {
        case .message(let message):
            message
        case .process(let executable, let status, let error):
            "\(executable) failed with status \(status): \(error)"
        }
    }
}

public struct AndroidAddonManager: Sendable {
    public let basePrefix: URL
    public let store: AndroidAddonStoreLayout
    public let trustKey: URL

    public init(
        basePrefix: URL,
        storeRoot: URL,
        persistentStateRoot: URL,
        trustKey: URL? = nil
    ) throws {
        guard basePrefix.path.first == "/" else {
            throw AndroidAddonManagementFailure.message(
                "Nucleus base prefix must be absolute")
        }
        self.basePrefix = basePrefix.standardizedFileURL
        self.store = try AndroidAddonStoreLayout(
            root: storeRoot,
            persistentStateRoot: persistentStateRoot)
        self.trustKey =
            trustKey?.standardizedFileURL
            ?? self.basePrefix.appendingPathComponent(
                "share/nucleus/trust/android-addon-publisher.pem")
    }

    public func install(artifact: URL) throws {
        let artifact = artifact.standardizedFileURL
        try FileManager.default.createDirectory(
            at: store.generations,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: store.persistentStateRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: store.persistentStateRoot.path)

        let candidate = store.generations.appendingPathComponent(
            ".candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: artifact, to: candidate)
        defer { try? FileManager.default.removeItem(at: candidate) }
        let manifest = try validateArtifact(candidate)
        let generationName = try sha256(
            candidate.appendingPathComponent("addon-manifest.json")
        ).prefix(24)
        let generation = store.generations.appendingPathComponent(
            String(generationName), isDirectory: true)
        if FileManager.default.fileExists(atPath: generation.path) {
            _ = try validateArtifact(generation)
        } else {
            try synchronizeTree(candidate)
            try FileManager.default.moveItem(at: candidate, to: generation)
            try synchronizeDirectory(store.generations)
        }
        try activate(generation: generation)
        try publishCapability()
        print(
            "installed Android add-on \(manifest.release) \(manifest.buildNumber) "
                + "(\(manifest.architecture.rawValue))")
    }

    public func deactivate() throws {
        try removeActivation()
        print(
            "deactivated Android add-on; persistent state retained at "
                + store.persistentStateRoot.path)
    }

    public func uninstall() throws {
        try removeActivation()
        if FileManager.default.fileExists(atPath: store.generations.path) {
            try FileManager.default.removeItem(at: store.generations)
            try synchronizeDirectory(store.root)
        }
        print(
            "uninstalled Android add-on; persistent state retained at "
                + store.persistentStateRoot.path)
    }

    public func activeManifest() throws -> AndroidAddonManifest? {
        let path = store.active.appendingPathComponent("addon-manifest.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        return try JSONDecoder().decode(
            AndroidAddonManifest.self,
            from: Data(contentsOf: path))
    }

    private func validateArtifact(_ artifact: URL) throws -> AndroidAddonManifest {
        let artifactValues = try artifact.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard artifactValues.isDirectory == true,
            artifactValues.isSymbolicLink != true
        else {
            throw AndroidAddonManagementFailure.message(
                "Android add-on artifact must be a real directory: \(artifact.path)")
        }
        let manifestURL = artifact.appendingPathComponent("addon-manifest.json")
        let signatureURL = artifact.appendingPathComponent("addon-manifest.json.sig")
        for path in [manifestURL, signatureURL, trustKey] {
            try requireRegularFile(path)
        }
        _ = try run(
            "openssl",
            [
                "dgst", "-sha256", "-verify", trustKey.path,
                "-signature", signatureURL.path, manifestURL.path,
            ])
        let manifest = try JSONDecoder().decode(
            AndroidAddonManifest.self,
            from: Data(contentsOf: manifestURL))
        let compatibilityURL = basePrefix.appendingPathComponent(
            "share/nucleus/android-addon-compatibility.json")
        try requireRegularFile(compatibilityURL)
        let compatibility = try JSONDecoder().decode(
            AndroidAddonCompatibility.self,
            from: Data(contentsOf: compatibilityURL))
        try manifest.validateCompatibility(compatibility)
        try validatePayload(manifest, artifact: artifact)
        let provenance = try JSONDecoder().decode(
            AndroidImageProvenance.self,
            from: Data(
                contentsOf: artifact.appendingPathComponent(
                    "image-provenance.json")))
        try validateAndroidAddonImageProvenance(
            manifest: manifest,
            provenance: provenance)
        _ = try run(
            artifact.appendingPathComponent("libexec/android-tools/avbtool").path,
            [
                "verify_image", "--image",
                artifact.appendingPathComponent("images/vbmeta.img").path,
                "--key",
                artifact.appendingPathComponent(
                    "share/nucleus/android/avb-release-key.pem"
                ).path,
                "--follow_chain_partitions",
            ])
        return manifest
    }

    private func removeActivation() throws {
        try removeIfPresent(store.activeCapabilityManifest)
        try removeIfPresent(store.active)
        try synchronizeDirectory(store.root)
    }

    private func validatePayload(
        _ manifest: AndroidAddonManifest,
        artifact: URL
    ) throws {
        let required = Set([
            "image-provenance.json",
            "images/system.img",
            "images/system_ext.img",
            "images/product.img",
            "images/vendor.img",
            "images/vbmeta.img",
            "images/vbmeta_system.img",
            "libexec/nucleus-android-runtime",
            "libexec/nucleus-android-runtime-privileged",
            "libexec/nucleus-android-gfxstream-broker",
            "libexec/nucleus-android-display-host",
            "libexec/android-tools/avbtool",
            "share/nucleus/android/avb-release-key.pem",
            "share/nucleus/android/lxc-nucleus-android.apparmor",
            "share/nucleus/android/nucleus-android.seccomp",
        ])
        let declared = Set(manifest.payload.map(\.path))
        guard required.isSubset(of: declared) else {
            throw AndroidAddonManagementFailure.message(
                "Android add-on payload is missing required products: "
                    + required.subtracting(declared).sorted().joined(separator: ", "))
        }
        for file in manifest.payload {
            let path = artifact.appendingPathComponent(file.path)
            let values = try path.resourceValues(
                forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
            guard let size = values.fileSize, size >= 0,
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                UInt64(size) == file.size,
                try hasExecutableMode(path) == file.executable,
                try sha256(path) == file.sha256
            else {
                throw AndroidAddonManagementFailure.message(
                    "Android add-on payload does not match its manifest: \(file.path)")
            }
        }
        let allowed = declared.union([
            "addon-manifest.json", "addon-manifest.json.sig",
        ])
        let enumerator = FileManager.default.enumerator(
            at: artifact,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
        while let path = enumerator?.nextObject() as? URL {
            let values = try path.resourceValues(
                forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ])
            guard values.isSymbolicLink != true else {
                throw AndroidAddonManagementFailure.message(
                    "Android add-on artifact contains a symbolic link: \(path.path)")
            }
            if values.isDirectory == true { continue }
            let relative = String(path.path.dropFirst(artifact.path.count + 1))
            guard values.isRegularFile == true, allowed.contains(relative) else {
                throw AndroidAddonManagementFailure.message(
                    "Android add-on artifact contains undeclared content: \(relative)")
            }
        }
    }

    private func activate(generation: URL) throws {
        try FileManager.default.createDirectory(
            at: store.root, withIntermediateDirectories: true)
        let candidate = store.root.appendingPathComponent(
            ".current-candidate-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            atPath: candidate.path,
            withDestinationPath:
                "generations/\(generation.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: candidate) }
        guard unsafe rename(candidate.path, store.active.path) == 0 else {
            throw AndroidAddonManagementFailure.message(
                "could not atomically activate Android add-on: errno \(errno)")
        }
        try synchronizeDirectory(store.root)
    }

    private func publishCapability() throws {
        try FileManager.default.createDirectory(
            at: store.capabilityRegistry,
            withIntermediateDirectories: true)
        let declaration = CapabilityDeclaration(
            identifier: AndroidAddonManifest.identifier,
            executable: store.active.appendingPathComponent(
                "libexec/nucleus-android-runtime"
            ).path,
            arguments: [
                "--addon-root", store.root.path,
                "--state-root", store.persistentStateRoot.path,
            ],
            shutdownTimeoutSeconds: 60)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Array(try encoder.encode(declaration))
        bytes.append(0x0a)
        try writeAtomic(
            Data(bytes),
            to: store.activeCapabilityManifest)
    }

    // The session decoder supplies the same-build defaults for restart policy,
    // retry count, and protocol version. Keeping this writer to the required
    // fields avoids coupling the independently downloadable add-on manager to
    // the session protocol's dynamic-library product.
    private struct CapabilityDeclaration: Encodable {
        let identifier: String
        let executable: String
        let arguments: [String]
        let shutdownTimeoutSeconds: UInt16
    }

    private func sha256(_ path: URL) throws -> String {
        let output = try run("sha256sum", ["--", path.path])
        guard let digest = output.split(whereSeparator: \.isWhitespace).first,
            digest.count == 64,
            digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw AndroidAddonManagementFailure.message(
                "sha256sum returned invalid output for \(path.path)")
        }
        return String(digest)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AndroidAddonManagementFailure.process(
                executable: executable,
                status: process.terminationStatus,
                error: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requireRegularFile(_ path: URL) throws {
        let values = try path.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AndroidAddonManagementFailure.message(
                "required Android add-on file is unavailable: \(path.path)")
        }
    }

    private func hasExecutableMode(_ path: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: path.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw AndroidAddonManagementFailure.message(
                "could not read payload permissions: \(path.path)")
        }
        return permissions.uint16Value & 0o111 != 0
    }

    private func removeIfPresent(_ path: URL) throws {
        do {
            try FileManager.default.removeItem(at: path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private func writeAtomic(_ data: Data, to destination: URL) throws {
        let candidate = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        try data.write(to: candidate)
        let handle = try FileHandle(forWritingTo: candidate)
        try handle.synchronize()
        try handle.close()
        guard unsafe rename(candidate.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: candidate)
            throw AndroidAddonManagementFailure.message(
                "could not atomically publish \(destination.path): errno \(errno)")
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private func synchronizeTree(_ root: URL) throws {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey])
        var directories: [URL] = [root]
        while let path = enumerator?.nextObject() as? URL {
            let values = try path.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                directories.append(path)
            } else {
                try synchronizeFile(path)
            }
        }
        for directory in directories.reversed() {
            try synchronizeDirectory(directory)
        }
    }

    private func synchronizeFile(_ path: URL) throws {
        let descriptor = unsafe open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AndroidAddonManagementFailure.message(
                "could not open \(path.path) for synchronization: errno \(errno)")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw AndroidAddonManagementFailure.message(
                "could not synchronize \(path.path): errno \(errno)")
        }
    }

    private func synchronizeDirectory(_ path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let descriptor = unsafe open(
            path.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AndroidAddonManagementFailure.message(
                "could not open directory \(path.path): errno \(errno)")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw AndroidAddonManagementFailure.message(
                "could not synchronize directory \(path.path): errno \(errno)")
        }
    }
}
#endif
