import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum ToolchainSystemOperation: String, Sendable {
    case install
    case uninstall

    var entryPoint: String { "__toolchain-system-\(rawValue)" }
}

struct ToolchainSystemRequest: Sendable {
    let operation: ToolchainSystemOperation
    let version: String
    let prefix: URL
    let tarball: URL?
    let artifactID: String?

    static func parse(_ arguments: [String]) throws -> ToolchainSystemRequest? {
        guard let entryPoint = arguments.first,
            let operation = ToolchainSystemOperation.allCasesByEntryPoint[entryPoint]
        else {
            return nil
        }
        let expectedCount = operation == .install ? 5 : 3
        guard arguments.count == expectedCount else {
            throw WorkspaceFailure.message("invalid privileged toolchain request")
        }
        let version = try validateVersion(arguments[1])
        let prefix = try validatePrefix(arguments[2])
        if operation == .uninstall {
            return ToolchainSystemRequest(
                operation: operation,
                version: version,
                prefix: prefix,
                tarball: nil,
                artifactID: nil)
        }
        let tarball = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        guard arguments[3].hasPrefix("/"),
            FileManager.default.isReadableFile(atPath: tarball.path)
        else {
            throw WorkspaceFailure.message("toolchain archive is not a readable absolute path")
        }
        let artifactID = arguments[4]
        guard artifactID.hasPrefix("sha256:"), artifactID.count == 71,
            artifactID.dropFirst("sha256:".count).allSatisfy(\.isHexDigit)
        else {
            throw WorkspaceFailure.message("invalid toolchain artifact identity")
        }
        return ToolchainSystemRequest(
            operation: operation,
            version: version,
            prefix: prefix,
            tarball: tarball,
            artifactID: artifactID)
    }

    static func validateVersion(_ value: String) throws -> String {
        guard !value.isEmpty,
            value.first?.isLetter == true || value.first?.isNumber == true,
            !value.contains(".."),
            value.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) })
        else {
            throw WorkspaceFailure.message("invalid Swift toolchain version '\(value)'")
        }
        return value
    }

    static func validatePrefix(_ value: String) throws -> URL {
        let resolved = URL(
            fileURLWithPath: value, isDirectory: true
        ).standardizedFileURL
        guard value.hasPrefix("/"), resolved.path != "/" else {
            throw WorkspaceFailure.message(
                "toolchain install prefix must be an absolute non-root path")
        }
        return resolved
    }
}

extension ToolchainSystemOperation {
    fileprivate static let allCasesByEntryPoint: [String: ToolchainSystemOperation] = [
        ToolchainSystemOperation.install.entryPoint: .install,
        ToolchainSystemOperation.uninstall.entryPoint: .uninstall,
    ]
}

public enum ToolchainSystemEntryPoint {
    public static func executeIfRequested(arguments: [String]) throws -> Bool {
        guard let request = try ToolchainSystemRequest.parse(arguments) else {
            return false
        }
        guard geteuid() == 0 else {
            throw WorkspaceFailure.message(
                "privileged toolchain mutation must be invoked through sudo")
        }
        try ToolchainSystemInstaller(request: request).run()
        return true
    }
}

struct ToolchainSystemInstaller {
    private let request: ToolchainSystemRequest
    private let fileManager = FileManager.default
    private let profile: URL
    private let ownerAccountID: UInt32
    private let groupOwnerAccountID: UInt32

    init(
        request: ToolchainSystemRequest,
        profile: URL = URL(fileURLWithPath: "/etc/profile.d/nucleus-swift.sh"),
        ownerAccountID: UInt32 = 0,
        groupOwnerAccountID: UInt32 = 0
    ) {
        self.request = request
        self.profile = profile
        self.ownerAccountID = ownerAccountID
        self.groupOwnerAccountID = groupOwnerAccountID
    }

    func run() throws {
        switch request.operation {
        case .install:
            try install()
        case .uninstall:
            try uninstall()
        }
    }

    private func install() throws {
        guard let sourceArchive = request.tarball,
            let expectedArtifactID = request.artifactID
        else {
            throw WorkspaceFailure.message("toolchain installation input is incomplete")
        }
        try fileManager.createDirectory(
            at: request.prefix,
            withIntermediateDirectories: true)

        let nonce = UUID().uuidString
        let staging = request.prefix.appendingPathComponent(".stage-\(nonce)")
        let archive = staging.appendingPathComponent("toolchain.tar.gz")
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        let target = request.prefix.appendingPathComponent(request.version)
        let replacement = target.appendingPathComponent("usr")
        let backup = target.appendingPathComponent(".usr.replaced-\(nonce)")
        let current = request.prefix.appendingPathComponent("current")
        let currentCandidate = request.prefix.appendingPathComponent(".current-\(nonce)")
        let profileCandidate = profile.deletingLastPathComponent()
            .appendingPathComponent(".nucleus-swift.sh-\(nonce)")

        var replacementPublished = false
        var priorReplacementMovedAside = false
        var currentPublished = false
        let priorCurrent = try symbolicLinkDestination(at: current)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: currentCandidate)
            try? fileManager.removeItem(at: profileCandidate)
        }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            try fileManager.copyItem(at: sourceArchive, to: archive)
            let actualArtifactID = try ArtifactHasher.digest(
                file: FilePath(archive.path)
            ).description
            guard actualArtifactID == expectedArtifactID else {
                throw WorkspaceFailure.message(
                    "toolchain archive changed after Collider validated it")
            }
            try validateArchivePaths(archive)
            try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false)
            try runProcess(
                "/usr/bin/tar",
                [
                    "--extract", "--gzip", "--no-same-owner", "--no-same-permissions",
                    "--file", archive.path, "--directory", extracted.path,
                ])

            let stagedToolchain = extracted.appendingPathComponent("usr")
            try validateToolchain(at: stagedToolchain)
            try validateContainedSymbolicLinks(at: stagedToolchain)
            try normalizeOwnershipAndPermissions(at: stagedToolchain)
            print("Verifying staged toolchain...")
            try runProcess(
                stagedToolchain.appendingPathComponent("bin/swift").path,
                ["--version"],
                discardOutput: true)

            try writeProfileCandidate(profileCandidate)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            guard !lexicallyExists(backup) else {
                throw WorkspaceFailure.message(
                    "refusing to replace unexpected rollback path: \(backup.path)")
            }
            if lexicallyExists(replacement) {
                try fileManager.moveItem(at: replacement, to: backup)
                priorReplacementMovedAside = true
            }
            try fileManager.moveItem(at: stagedToolchain, to: replacement)
            replacementPublished = true

            if lexicallyExists(current), priorCurrent == nil {
                throw WorkspaceFailure.message(
                    "refusing to replace non-symlink path: \(current.path)")
            }
            try fileManager.createSymbolicLink(
                atPath: currentCandidate.path,
                withDestinationPath: request.version)
            try atomicReplace(currentCandidate, current)
            currentPublished = true

            print("Verifying installed toolchain...")
            try runProcess(
                current.appendingPathComponent("usr/bin/swift").path,
                ["--version"])
            try atomicReplace(profileCandidate, profile)

            if priorReplacementMovedAside {
                try? fileManager.removeItem(at: backup)
            }
            print("Installed Nucleus Swift \(request.version) at \(replacement.path)")
        } catch {
            if replacementPublished {
                try? fileManager.removeItem(at: replacement)
            }
            if priorReplacementMovedAside, lexicallyExists(backup) {
                try? fileManager.moveItem(at: backup, to: replacement)
            }
            if currentPublished {
                try? fileManager.removeItem(at: current)
                if let priorCurrent {
                    let rollback = request.prefix.appendingPathComponent(
                        ".current-rollback-\(nonce)")
                    try? fileManager.createSymbolicLink(
                        atPath: rollback.path,
                        withDestinationPath: priorCurrent)
                    try? atomicReplace(rollback, current)
                }
            }
            throw error
        }
    }

    private func uninstall() throws {
        let target = request.prefix.appendingPathComponent(request.version)
        let current = request.prefix.appendingPathComponent("current")
        let selectedVersion = try symbolicLinkDestination(at: current)

        if lexicallyExists(target) {
            print("Removing \(target.path)")
            try fileManager.removeItem(at: target)
        }
        if selectedVersion == request.version {
            print("Removing \(current.path)")
            try fileManager.removeItem(at: current)
            if lexicallyExists(profile) {
                print("Removing \(profile.path)")
                try fileManager.removeItem(at: profile)
            }
        }
        _ = unsafe rmdir(request.prefix.path)
        print("Uninstalled Nucleus Swift \(request.version)")
    }

    private func validateArchivePaths(_ archive: URL) throws {
        let listing = try runProcess(
            "/usr/bin/tar", ["--list", "--gzip", "--file", archive.path],
            captureOutput: true)
        for rawPath in listing.split(whereSeparator: \.isNewline) {
            let path = String(rawPath)
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"),
                !components.contains(".."),
                !components.contains("."),
                components.first == "usr"
            else {
                throw WorkspaceFailure.message(
                    "toolchain archive contains an unsafe path: \(path)")
            }
        }
    }

    private func validateToolchain(at usr: URL) throws {
        let requiredFiles = [
            "bin/swift",
            "lib/swift/linux/lib_CFXMLInterface.a",
            "lib/swift_static/linux/lib_CFXMLInterface.a",
            "lib/swift_static/linux/static-stdlib-args.lnk",
        ]
        for path in requiredFiles {
            guard
                fileManager.fileExists(
                    atPath: usr.appendingPathComponent(path).path)
            else {
                throw WorkspaceFailure.message(
                    "toolchain artifact is incomplete: usr/\(path) is missing")
            }
        }
        let linkArguments = try String(
            contentsOf: usr.appendingPathComponent(
                "lib/swift_static/linux/static-stdlib-args.lnk"),
            encoding: .utf8)
        for argument in ["-lswift_StringProcessing", "-l_CFXMLInterface", "-lxml2"] {
            guard linkArguments.contains(argument) else {
                throw WorkspaceFailure.message(
                    "toolchain static link metadata is missing \(argument)")
            }
        }
    }

    private func normalizeOwnershipAndPermissions(at root: URL) throws {
        try setAttributes(at: root, permissions: 0o755)
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [])
        else {
            throw WorkspaceFailure.message("could not enumerate staged toolchain")
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                try setAttributes(at: item, permissions: 0o755)
            } else if values.isRegularFile == true {
                let attributes = try fileManager.attributesOfItem(atPath: item.path)
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                try setAttributes(
                    at: item,
                    permissions: mode & 0o111 == 0 ? 0o644 : 0o755)
            }
        }
    }

    private func validateContainedSymbolicLinks(at root: URL) throws {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [])
        else {
            throw WorkspaceFailure.message("could not inspect staged toolchain links")
        }
        let rootPath = root.standardizedFileURL.path
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(rootPath + "/") else {
                throw WorkspaceFailure.message(
                    "toolchain archive contains an escaping symbolic link: \(item.path)")
            }
        }
    }

    private func setAttributes(at url: URL, permissions: Int) throws {
        try fileManager.setAttributes(
            [
                .ownerAccountID: NSNumber(value: ownerAccountID),
                .groupOwnerAccountID: NSNumber(value: groupOwnerAccountID),
                .posixPermissions: NSNumber(value: permissions),
            ],
            ofItemAtPath: url.path)
    }

    private func writeProfileCandidate(_ candidate: URL) throws {
        let bin = shellSingleQuoted(
            request.prefix.appendingPathComponent("current/usr/bin").path)
        let contents = """
            # Nucleus Swift toolchain — installed by Collider.
            nucleus_swift_bin=\(bin)
            if [ -x "$nucleus_swift_bin/swift" ]; then
              case ":$PATH:" in
                *:"$nucleus_swift_bin":*) ;;
                *) PATH="$nucleus_swift_bin:$PATH" ;;
              esac
              export PATH
            fi
            unset nucleus_swift_bin

            """
        try Data(contents.utf8).write(to: candidate, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: candidate.path)
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacing("'", with: "'\"'\"'") + "'"
    }

    private func lexicallyExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func symbolicLinkDestination(at url: URL) throws -> String? {
        if let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: url.path)
        {
            return destination
        }
        if fileManager.fileExists(atPath: url.path) {
            return nil
        }
        return nil
    }

    private func atomicReplace(_ source: URL, _ destination: URL) throws {
        guard unsafe rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    @discardableResult
    private func runProcess(
        _ executable: String,
        _ arguments: [String],
        captureOutput: Bool = false,
        discardOutput: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        if captureOutput {
            process.standardOutput = output
        } else if discardOutput {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        let captured =
            captureOutput
            ? output.fileHandleForReading.readDataToEndOfFile()
            : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorkspaceFailure.process(
                [executable] + arguments, process.terminationStatus)
        }
        if captureOutput {
            return String(
                decoding: captured,
                as: UTF8.self)
        }
        return ""
    }
}
