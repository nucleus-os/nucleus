#if os(Linux)
import ColliderCore
import Foundation
import NucleusAndroidRuntimeCore
import SystemPackage

struct InstallRuntimeAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let products: FilePath
        let prefix: FilePath
        let generationsRoot: FilePath
        let sessionPackage: FilePath
        let kernelContract: FilePath
        let trustKey: FilePath?
        let buildMetadata: String

        func encode(into encoder: inout CanonicalDigestEncoder) {
            encoder.append(tag: 1, string: products.string)
            encoder.append(tag: 2, string: prefix.string)
            encoder.append(tag: 3, string: generationsRoot.string)
            encoder.append(tag: 4, string: sessionPackage.string)
            encoder.append(tag: 5, string: kernelContract.string)
            encoder.append(tag: 6, string: trustKey?.string ?? "")
            encoder.append(tag: 7, string: buildMetadata)
        }
    }

    static let kind = "shell.install-runtime"

    let products: FilePath
    let prefix: FilePath
    let generationsRoot: FilePath
    let sessionPackage: FilePath
    let kernelContract: FilePath
    let trustKey: FilePath?
    let buildMetadata: String
    let environment: [String: String]

    var identity: Identity {
        Identity(
            products: products,
            prefix: prefix,
            generationsRoot: generationsRoot,
            sessionPackage: sessionPackage,
            kernelContract: kernelContract,
            trustKey: trustKey,
            buildMetadata: buildMetadata)
    }

    init(configuration: ShellRuntimeInstallConfiguration) {
        products = configuration.swiftPM.configurationProducts
        prefix = configuration.prefix
        generationsRoot = configuration.generationsRoot
        sessionPackage = configuration.sessionPackage
        kernelContract = configuration.kernelContract
        trustKey = configuration.trustKey
        buildMetadata = configuration.buildMetadata
        environment = configuration.environment
    }

    func execute(in context: ActionContext) async throws {
        if let metadata = try context.files.metadataWithoutFollowingSymlinks(
            for: prefix),
            metadata.type != .symbolicLink
        {
            throw RuntimeInstallFailure(
                "installation path must be absent or an active-generation symlink: \(prefix)")
        }

        try context.files.createDirectory(generationsRoot)
        let candidate = generationsRoot.appending(".candidate-runtime")
        try context.files.remove(candidate)
        for directory in ["bin", "lib", "libexec", "share/nucleus"] {
            try context.files.createDirectory(candidate.appending(directory))
        }
        var published = false
        defer {
            if !published { try? context.files.remove(candidate) }
        }

        try await stageRuntimeELF(
            products: products,
            prefix: candidate,
            environment: environment,
            productSet: .baseRuntime,
            context: context)
        try await installSessionFiles(candidate: candidate, context: context)
        try context.files.write(
            Array(buildMetadata.utf8),
            to: candidate.appending("share/nucleus/runtime-build.txt"))
        try await installTrustRoot(candidate: candidate, context: context)
        try validateStructure(candidate, files: context.files)

        let report = candidate.appending("share/nucleus/runtime-elf-report.json")
        try await validateRuntimeELF(
            root: candidate,
            report: report,
            environment: environment,
            productSet: .baseRuntime,
            context: context)
        try await validateRelocation(candidate: candidate, context: context)
        try writeCompatibility(candidate: candidate, files: context.files)

        let digest = try context.files.digest(tree: candidate)
        let generation = generationsRoot.appending(
            hex(digest.bytes.prefix(12)))
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generation,
            active: prefix)
        published = true
        try context.files.pruneDirectories(
            DirectoryRetentionPlan(
                safetyRoot: generationsRoot.removingLastComponent(),
                rules: [
                    DirectoryRetentionRule(
                        root: generationsRoot,
                        current: prefix,
                        retain: 3,
                        naming: .contentIdentity)
                ]))
    }

    private func installSessionFiles(
        candidate: FilePath,
        context: ActionContext
    ) async throws {
        for name in ["nucleus-session", "nucleus-session-validate"] {
            let source = sessionPackage.appending(name)
            try await requireSuccess(
                CommandSpec(
                    executable: .named("bash"),
                    arguments: ["-n", source.string],
                    workingDirectory: sessionPackage,
                    environment: environment),
                context: context)
            let destination = candidate.appending("bin").appending(name)
            try context.files.copy(from: source, to: destination)
            try context.files.setPermissions(0o755, for: destination)
        }

        let template = String(
            decoding: try context.files.read(
                sessionPackage.appending("nucleus@.service")),
            as: UTF8.self)
        let unit = candidate.appending("share/systemd/user/nucleus@.service")
        let validation = template.replacing(
            "@bindir@",
            with: candidate.appending("bin").string)
        try context.files.write(Array(validation.utf8), to: unit)
        try await requireSuccess(
            CommandSpec(
                executable: .named("systemd-analyze"),
                arguments: [
                    "--user", "--recursive-errors=no", "verify", unit.string,
                ],
                workingDirectory: candidate,
                environment: environment),
            context: context)
        let published = template.replacing(
            "@bindir@",
            with: prefix.appending("bin").string)
        try context.files.write(Array(published.utf8), to: unit)
    }

    private func installTrustRoot(
        candidate: FilePath,
        context: ActionContext
    ) async throws {
        guard let trustKey else { return }
        guard
            try context.files.metadataWithoutFollowingSymlinks(for: trustKey)?.type
                == .regular
        else {
            throw RuntimeInstallFailure(
                "Android add-on trust key must be a regular file: \(trustKey)")
        }
        try await requireSuccess(
            CommandSpec(
                executable: .named("openssl"),
                arguments: ["pkey", "-pubin", "-in", trustKey.string, "-noout"],
                workingDirectory: trustKey.removingLastComponent(),
                environment: environment),
            context: context)
        try context.files.copy(
            from: trustKey,
            to: candidate.appending(
                "share/nucleus/trust/android-addon-publisher.pem"))
    }

    private func validateStructure(
        _ candidate: FilePath,
        files: ActionFileSystem
    ) throws {
        for path in [
            "bin/nucleus-session",
            "libexec/NucleusSessionSupervisor",
            "libexec/NucleusConfigService",
            "libexec/NucleusControlService",
            "bin/NucleusCompositor",
            "bin/NucleusShell",
            "bin/nucleus",
            "libexec/NucleusShellPamHelper",
        ] {
            guard let metadata = try files.metadata(for: candidate.appending(path)),
                metadata.type == .regular,
                metadata.ownerExecutable
            else {
                throw RuntimeInstallFailure(
                    "runtime candidate is missing executable \(path)")
            }
        }
    }

    private func validateRelocation(
        candidate: FilePath,
        context: ActionContext
    ) async throws {
        let relocated = generationsRoot.appending(".relocation-runtime")
        try context.files.remove(relocated)
        try context.files.move(from: candidate, to: relocated)
        do {
            try await validateRuntimeELF(
                root: relocated,
                report: relocated.appending(
                    "share/nucleus/runtime-elf-report.json"),
                environment: environment,
                productSet: .baseRuntime,
                context: context)
            try context.files.move(from: relocated, to: candidate)
        } catch {
            try? context.files.move(from: relocated, to: candidate)
            throw error
        }
    }

    private func writeCompatibility(
        candidate: FilePath,
        files: ActionFileSystem
    ) throws {
        let relativePath = "share/nucleus/android-addon-compatibility.json"
        let buildIdentity = try files.digest(
            tree: candidate,
            excluding: [relativePath])
        let kernelIdentity = try files.digest(file: kernelContract)
        #if arch(arm64)
        let architecture = AndroidAddonArchitecture.arm64
        #elseif arch(x86_64)
        let architecture = AndroidAddonArchitecture.x86_64
        #else
        #error("Nucleus supports Android add-ons only on arm64 and x86_64")
        #endif
        let compatibility = try AndroidAddonCompatibility(
            nucleusBuildIdentity: hex(buildIdentity.bytes),
            kernelCapabilityIdentity: hex(kernelIdentity.bytes),
            architecture: architecture)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Array(try encoder.encode(compatibility))
        bytes.append(0x0a)
        try files.write(bytes, to: candidate.appending(relativePath))
    }

    private func requireSuccess(
        _ command: CommandSpec,
        context: ActionContext
    ) async throws {
        let result = try await context.execute(command)
        guard result.status == 0 else {
            throw RuntimeInstallFailure(
                "command failed with status \(result.status): \(result.standardOutput)")
        }
    }
}

private func hex(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var encoded: [UInt8] = []
    for byte in bytes {
        encoded.append(digits[Int(byte >> 4)])
        encoded.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: encoded, as: UTF8.self)
}

struct RuntimeInstallFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = "runtime installation failed: \(description)"
    }
}
#endif
