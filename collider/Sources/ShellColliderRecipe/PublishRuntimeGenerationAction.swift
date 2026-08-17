#if os(Linux)
import ColliderCore
import Foundation
import SystemPackage

package struct PublishRuntimeGenerationAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let products: FilePath
        let prefix: FilePath
        let generationsRoot: FilePath
        let packageManifestsRoot: FilePath
        let rollbackGenerationCount: UInt32
        let sessionPackage: FilePath
        let buildMetadata: String
        let targetArchitecture: PlatformArchitecture

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: products)
            encoder.append(path: prefix)
            encoder.append(path: generationsRoot)
            encoder.append(path: packageManifestsRoot)
            encoder.append(UInt64(rollbackGenerationCount))
            encoder.append(path: sessionPackage)
            encoder.append(buildMetadata)
            encoder.append(targetArchitecture.rawValue)
        }
    }

    package static let kind: ActionKind = "shell.publish-runtime-generation"

    let products: FilePath
    let prefix: FilePath
    let generationsRoot: FilePath
    let packageManifestsRoot: FilePath
    let rollbackGenerationCount: UInt32
    let sessionPackage: FilePath
    let buildMetadata: String
    let targetArchitecture: PlatformArchitecture
    package let environment: [String: String]

    package var identity: Identity {
        Identity(
            products: products,
            prefix: prefix,
            generationsRoot: generationsRoot,
            packageManifestsRoot: packageManifestsRoot,
            rollbackGenerationCount: rollbackGenerationCount,
            sessionPackage: sessionPackage,
            buildMetadata: buildMetadata,
            targetArchitecture: targetArchitecture)
    }

    package var requirements: ActionRequirements {
        let effects = [
            ActionEffect(.read, scope: .input(products)),
            ActionEffect(.read, scope: .checkout(sessionPackage)),
            ActionEffect(.read, scope: .unrestricted(FilePath("/"))),
            ActionEffect(
                .readWrite,
                scope: .unrestricted(FilePath("/tmp/nucleus-systemd-analyze"))),
            ActionEffect(.readWrite, scope: .scratch(generationsRoot)),
            ActionEffect(.readWrite, scope: .publication(packageManifestsRoot)),
            ActionEffect(.readWrite, scope: .publication(prefix)),
        ]
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "bash", executable: .named("bash"), role: .operational),
                ActionToolRequirement(
                    "patchelf", executable: .named("patchelf"), role: .semantic),
                ActionToolRequirement(
                    "readelf", executable: .named("readelf"), role: .semantic),
                ActionToolRequirement(
                    "llvm-strip", executable: .named("llvm-strip"), role: .semantic),
                ActionToolRequirement(
                    "systemd-analyze",
                    executable: .named("systemd-analyze"),
                    role: .operational),
            ],
            effects: effects,
            executionPlatform: ExecutionPlatform(
                environment: .native,
                operatingSystem: .linux,
                architecture: RunnerPlatform.current.architecture),
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: targetArchitecture,
                abi: "glibc"))
    }

    init(configuration: ShellRuntimePublicationConfiguration) {
        products = configuration.swiftPM.productsDirectory
        prefix = configuration.prefix
        generationsRoot = configuration.generationsRoot
        packageManifestsRoot = configuration.packageManifestsRoot
        rollbackGenerationCount = ShellColliderRecipe.rollbackGenerationCount
        sessionPackage = configuration.sessionPackage
        buildMetadata = configuration.buildMetadata
        targetArchitecture = RunnerPlatform.current.architecture
        environment = configuration.environment
    }

    package init(
        products: FilePath,
        prefix: FilePath,
        generationsRoot: FilePath,
        packageManifestsRoot: FilePath,
        rollbackGenerationCount: UInt32,
        sessionPackage: FilePath,
        buildMetadata: String,
        targetArchitecture: PlatformArchitecture,
        environment: [String: String]
    ) {
        self.products = products
        self.prefix = prefix
        self.generationsRoot = generationsRoot
        self.packageManifestsRoot = packageManifestsRoot
        self.rollbackGenerationCount = rollbackGenerationCount
        self.sessionPackage = sessionPackage
        self.buildMetadata = buildMetadata
        self.targetArchitecture = targetArchitecture
        self.environment = environment
    }

    package func execute(in context: ActionContext) async throws {
        if let metadata = try context.files.metadataWithoutFollowingSymlinks(
            for: prefix),
            metadata.type != .symbolicLink
        {
            throw RuntimePublicationFailure(
                "active runtime path must be absent or a generation symlink: \(prefix)")
        }

        try context.files.createDirectory(generationsRoot)
        let candidate = generationsRoot.appending(".candidate-runtime")
        try context.files.remove(candidate)
        for directory in [
            "bin",
            "lib",
            "libexec",
            "share/nucleus",
            "share/nucleus/host-integration/pam",
            "share/nucleus/host-integration/systemd",
            "share/nucleus/host-integration/wayland",
        ] {
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
            targetArchitecture: targetArchitecture,
            context: context)
        try await stageHostIntegration(candidate: candidate, context: context)
        try context.files.write(
            Array(buildMetadata.utf8),
            to: candidate.appending("share/nucleus/runtime-build.txt"))
        try validateStructure(candidate, files: context.files)

        let report = candidate.appending("share/nucleus/runtime-elf-report.json")
        try await validateRuntimeELF(
            root: candidate,
            report: report,
            environment: environment,
            productSet: .baseRuntime,
            targetArchitecture: targetArchitecture,
            context: context)
        try await validateRelocation(candidate: candidate, context: context)

        let digest = try context.files.digest(tree: candidate)
        let generation = generationsRoot.appending(
            hex(digest.bytes.prefix(12)))
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generation,
            active: prefix)
        published = true
        try writePackageManifests(
            artifactDigest: digest.description,
            generationName: generation.lastComponent?.string ?? "",
            context: context)
        try context.files.pruneDirectories(
            DirectoryRetentionPlan(
                safetyRoot: generationsRoot.removingLastComponent(),
                rules: [
                    DirectoryRetentionRule(
                        root: generationsRoot,
                        current: prefix,
                        retain: rollbackGenerationCount,
                        naming: .contentIdentity),
                    DirectoryRetentionRule(
                        root: packageManifestsRoot,
                        current: packageManifestsRoot.appending("current"),
                        retain: rollbackGenerationCount,
                        naming: .contentIdentity),
                ]))
    }

    private func writePackageManifests(
        artifactDigest: String,
        generationName: String,
        context: ActionContext
    ) throws {
        guard !generationName.isEmpty else {
            throw RuntimePublicationFailure("runtime generation has no name")
        }
        let pamTemplate = String(
            decoding: try context.files.read(
                sessionPackage.appending("nucleus.pam.in")),
            as: UTF8.self)
        let systemdUnitTemplate = String(
            decoding: try context.files.read(
                sessionPackage.appending("nucleus@.service")),
            as: UTF8.self)
        let desktopEntryTemplate = String(
            decoding: try context.files.read(
                sessionPackage.appending("nucleus-wayland.desktop")),
            as: UTF8.self)
        let candidate = packageManifestsRoot.appending(".candidate")
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        for manifest in try LinuxDistributionPackaging.encodedManifests(
            architecture: targetArchitecture,
            artifactDigest: artifactDigest,
            systemdUnitTemplate: systemdUnitTemplate,
            desktopEntryTemplate: desktopEntryTemplate,
            pamTemplate: pamTemplate)
        {
            try context.files.write(
                manifest.bytes,
                to: candidate.appending("\(manifest.family.rawValue).json"))
        }
        try context.files.publishGeneration(
            candidate: candidate,
            generation: packageManifestsRoot.appending(generationName),
            active: packageManifestsRoot.appending("current"))
    }

    private func stageHostIntegration(
        candidate: FilePath,
        context: ActionContext
    ) async throws {
        var source: [String: [UInt8]] = [:]
        for name in RuntimeHostIntegration.sourceFiles {
            source[name] = try context.files.read(sessionPackage.appending(name))
        }
        for name in ["nucleus-session", "nucleus-session-validate"] {
            try await requireSuccess(
                CommandSpec(
                    executable: .named("bash"),
                    arguments: ["-n", sessionPackage.appending(name).string],
                    workingDirectory: sessionPackage,
                    environment: environment),
                context: context)
        }

        for file in try RuntimeHostIntegration.payload(
            source: source,
            architecture: targetArchitecture)
        {
            let destination = candidate.appending(file.path)
            try context.files.write(file.bytes, to: destination)
            if file.executable {
                try context.files.setPermissions(0o755, for: destination)
            }
        }

        guard let unitBytes = source["nucleus@.service"] else {
            throw RuntimePublicationFailure("missing nucleus@.service source")
        }
        let unitTemplate = String(decoding: unitBytes, as: UTF8.self)
        let unit = candidate.appending(".nucleus-systemd-validation.service")
        let validation = RuntimeHostIntegration.render(
            unitTemplate,
            activePrefix: candidate)
        try context.files.write(Array(validation.utf8), to: unit)
        let systemdRuntime = FilePath("/tmp/nucleus-systemd-analyze")
        try context.files.remove(systemdRuntime)
        try context.files.createDirectory(systemdRuntime)
        defer { try? context.files.remove(systemdRuntime) }
        var systemdEnvironment = environment
        systemdEnvironment["XDG_RUNTIME_DIR"] = systemdRuntime.string
        try await requireSuccess(
            CommandSpec(
                executable: .named("systemd-analyze"),
                arguments: [
                    "--user", "--recursive-errors=no", "verify", unit.string,
                ],
                workingDirectory: candidate,
                environment: systemdEnvironment),
            context: context)
        try context.files.remove(unit)
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
                throw RuntimePublicationFailure(
                    "runtime candidate is missing executable \(path)")
            }
        }
        for path in [
            "bin/nucleus-session-validate",
            "share/nucleus/host-integration/systemd/nucleus@.service.in",
            "share/nucleus/host-integration/wayland/nucleus.desktop.in",
            "share/nucleus/host-integration/pam/nucleus.pam.in",
            "share/nucleus/host-requirements.json",
        ] {
            guard try files.metadata(for: candidate.appending(path))?.type == .regular else {
                throw RuntimePublicationFailure(
                    "runtime candidate is missing host integration file \(path)")
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
                targetArchitecture: targetArchitecture,
                context: context)
            try context.files.move(from: relocated, to: candidate)
        } catch {
            try? context.files.move(from: relocated, to: candidate)
            throw error
        }
    }

    private func requireSuccess(
        _ command: CommandSpec,
        context: ActionContext
    ) async throws {
        let result = try await context.commands.execute(command)
        guard result.succeeded else {
            throw result.executionFailure(
                reason: "runtime publication command failed: \(result.standardOutput)")
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

struct RuntimePublicationFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = "runtime publication failed: \(description)"
    }
}
#endif
