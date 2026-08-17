import ColliderCore
import SystemPackage

public struct AndroidPackageInputConfiguration: RecipeConfiguration {
    public let swiftPM: SwiftPMInvocation
    public let runtimeRoot: FilePath?
    public let runtimeScratch: FilePath
    public let aospGeneration: FilePath
    public let usesManagedAOSPGeneration: Bool
    public let aospSigningKey: FilePath
    public let output: FilePath
    public let appArmorPolicy: FilePath
    public let seccompPolicy: FilePath
    public let environment: [String: String]

    public init(
        swiftPM: SwiftPMInvocation,
        runtimeRoot: FilePath?,
        runtimeScratch: FilePath,
        aospGeneration: FilePath,
        usesManagedAOSPGeneration: Bool,
        aospSigningKey: FilePath,
        output: FilePath,
        appArmorPolicy: FilePath,
        seccompPolicy: FilePath,
        environment: [String: String]
    ) {
        self.swiftPM = swiftPM
        self.runtimeRoot = runtimeRoot
        self.runtimeScratch = runtimeScratch
        self.aospGeneration = aospGeneration
        self.usesManagedAOSPGeneration = usesManagedAOSPGeneration
        self.aospSigningKey = aospSigningKey
        self.output = output
        self.appArmorPolicy = appArmorPolicy
        self.seccompPolicy = seccompPolicy
        self.environment = environment
    }
}

#if os(Linux)
import Foundation
import NucleusAndroidRuntimeCore
import ShellColliderRecipe

extension AndroidRuntimeColliderRecipe {
    static func packageInputTask(
        configuration: AndroidPackageInputConfiguration,
        repositoryRoot: FilePath,
        managedAOSPGeneration: ArtifactReference
    ) throws -> TaskDeclaration {
        let productNames = [
            "nucleus-android-runtime",
            "nucleus-android-runtime-privileged",
            "nucleus-android-gfxstream-broker",
            "nucleus-android-display-host",
        ]
        let products =
            configuration.runtimeRoot == nil
            ? productNames.map { product in
                configuration.swiftPM.product(
                    package: "nucleus",
                    product: product,
                    packageRoot: repositoryRoot,
                    environment: configuration.environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: configuration.swiftPM.executable(product),
                            validation: .executableFile)
                    ])
            } : []
        var inputs: [ArtifactInput] = [
            .file(configuration.aospSigningKey),
            .file(configuration.appArmorPolicy),
            .file(configuration.seccompPolicy),
        ]
        if !configuration.usesManagedAOSPGeneration {
            inputs.append(.tree(configuration.aospGeneration))
        }
        if let runtimeRoot = configuration.runtimeRoot {
            inputs.append(.tree(runtimeRoot))
        } else {
            inputs.append(configuration.swiftPM.identityInput)
        }
        var builder = TaskBuilder(
            id: TaskID(rawValue: "android-runtime.package-input"),
            component: descriptor.id)
        if configuration.usesManagedAOSPGeneration {
            builder.consume(managedAOSPGeneration)
        }
        let _: ArtifactReference = try builder.output(
            "package-input",
            path: configuration.output,
            validation: .nonEmptyDirectory)
        return builder.build(
            swiftProducts: products,
            inputs: inputs,
            locks: [
                .shared(
                    configuration.output.removingLastComponent().appending(
                        ".android-package-input.lock"))
            ],
            action:
                try AnyColliderAction(
                    MaterializeAndroidPackageInputAction(configuration: configuration)))
    }
}

struct MaterializeAndroidPackageInputAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let runtimeProducts: FilePath
        let runtimeRoot: FilePath?
        let runtimeScratch: FilePath
        let aospGeneration: FilePath
        let aospSigningKey: FilePath
        let output: FilePath
        let appArmorPolicy: FilePath
        let seccompPolicy: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: runtimeProducts)
            encoder.append(runtimeRoot?.string ?? "")
            encoder.append(path: runtimeScratch)
            encoder.append(path: aospGeneration)
            encoder.append(path: aospSigningKey)
            encoder.append(path: output)
            encoder.append(path: appArmorPolicy)
            encoder.append(path: seccompPolicy)
        }
    }

    static let kind: ActionKind = "android-runtime.package-input"

    let runtimeProducts: FilePath
    let runtimeRoot: FilePath?
    let runtimeScratch: FilePath
    let aospGeneration: FilePath
    let aospSigningKey: FilePath
    let output: FilePath
    let appArmorPolicy: FilePath
    let seccompPolicy: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(
            runtimeProducts: runtimeProducts,
            runtimeRoot: runtimeRoot,
            runtimeScratch: runtimeScratch,
            aospGeneration: aospGeneration,
            aospSigningKey: aospSigningKey,
            output: output,
            appArmorPolicy: appArmorPolicy,
            seccompPolicy: seccompPolicy)
    }

    var requirements: ActionRequirements {
        var effects = [
            ActionEffect(.read, scope: .input(runtimeProducts)),
            ActionEffect(.read, scope: .input(aospGeneration)),
            ActionEffect(.read, scope: .input(aospSigningKey)),
            ActionEffect(.read, scope: .checkout(appArmorPolicy)),
            ActionEffect(.read, scope: .checkout(seccompPolicy)),
            ActionEffect(.read, scope: .unrestricted(FilePath("/"))),
            ActionEffect(.readWrite, scope: .scratch(runtimeScratch)),
            ActionEffect(.readWrite, scope: .output(output.removingLastComponent())),
        ]
        if let runtimeRoot {
            effects.append(ActionEffect(.read, scope: .input(runtimeRoot)))
        }
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "avbtool",
                    executable: .path(
                        aospGeneration.appending("out/host/linux-x86/bin/avbtool")),
                    role: .semantic),
                ActionToolRequirement(
                    "openssl", executable: .named("openssl"), role: .semantic),
                ActionToolRequirement(
                    "patchelf", executable: .named("patchelf"), role: .semantic),
                ActionToolRequirement(
                    "llvm-strip", executable: .named("llvm-strip"), role: .semantic),
            ],
            effects: effects,
            executionPlatform: ExecutionPlatform(
                environment: .native,
                operatingSystem: .linux,
                architecture: RunnerPlatform.current.architecture),
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: RunnerPlatform.current.architecture,
                abi: "glibc"))
    }

    init(configuration: AndroidPackageInputConfiguration) {
        runtimeProducts = configuration.swiftPM.productsDirectory
        runtimeRoot = configuration.runtimeRoot
        runtimeScratch = configuration.runtimeScratch
        aospGeneration = configuration.aospGeneration
        aospSigningKey = configuration.aospSigningKey
        output = configuration.output
        appArmorPolicy = configuration.appArmorPolicy
        seccompPolicy = configuration.seccompPolicy
        environment = configuration.environment
    }

    func execute(in context: ActionContext) async throws {
        guard
            try context.files.metadataWithoutFollowingSymlinks(for: output) == nil
        else {
            throw AndroidPackageInputFailure(
                "output already exists: \(output)")
        }
        try context.files.createDirectory(output.removingLastComponent())
        try context.files.createDirectory(runtimeScratch)
        let candidate = runtimeScratch.appending("package-input-candidate")
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        defer { try? context.files.remove(candidate) }

        let buildArchitecture = currentArchitecture

        let generatedRuntime = runtimeRoot == nil
        let resolvedRuntime = runtimeRoot ?? runtimeScratch.appending("runtime")
        if generatedRuntime {
            try context.files.remove(resolvedRuntime)
            defer { try? context.files.remove(resolvedRuntime) }
            try await stageRuntimeELF(
                products: runtimeProducts,
                prefix: resolvedRuntime,
                environment: environment,
                productSet: .androidPackage,
                targetArchitecture:
                    buildArchitecture == .arm64 ? .arm64 : .x86_64,
                context: context)
        }

        let provenancePath = aospGeneration.appending(
            "signed/image-provenance.json")
        let provenance = try JSONDecoder().decode(
            AndroidImageProvenance.self,
            from: Data(try context.files.read(provenancePath)))
        let expectedProduct =
            switch buildArchitecture {
            case .arm64: "nucleus_arm64"
            case .x86_64: "nucleus_x86_64"
            }
        guard provenance.status == "signed", provenance.product == expectedProduct else {
            throw AndroidPackageInputFailure(
                "signed AOSP product \(provenance.product) does not match \(buildArchitecture.rawValue)"
            )
        }
        let requiredImages = Set([
            "system.img", "system_ext.img", "product.img", "vendor.img",
            "vbmeta.img", "vbmeta_system.img",
        ])
        guard Set(provenance.images.map(\.name)) == requiredImages,
            provenance.images.allSatisfy({ $0.storageFormat == "raw" })
        else {
            throw AndroidPackageInputFailure(
                "signed AOSP provenance does not declare the complete raw image set")
        }

        try requireDirectory(
            resolvedRuntime.appending("lib"),
            files: context.files)
        try context.files.copyTree(
            from: resolvedRuntime.appending("lib"),
            to: candidate.appending("lib"))
        for executable in [
            "nucleus-android-runtime",
            "nucleus-android-runtime-privileged",
            "nucleus-android-gfxstream-broker",
            "nucleus-android-display-host",
        ] {
            try copyRegularFile(
                from: resolvedRuntime.appending("libexec/\(executable)"),
                to: candidate.appending("libexec/\(executable)"),
                files: context.files)
        }
        try copyRegularFile(
            from: provenancePath,
            to: candidate.appending("image-provenance.json"),
            files: context.files)
        for image in provenance.images {
            let source = aospGeneration.appending("images/\(image.name)")
            guard
                let metadata = try context.files.metadataWithoutFollowingSymlinks(
                    for: source),
                metadata.type == .regular,
                metadata.size == image.size,
                hex(try context.files.digest(file: source).bytes) == image.sha256
            else {
                throw AndroidPackageInputFailure(
                    "signed AOSP image does not match provenance: \(image.name)")
            }
            try copyRegularFile(
                from: source,
                to: candidate.appending("images/\(image.name)"),
                files: context.files)
        }

        try copyPortableAVBTool(
            from: aospGeneration.appending("out/host/linux-x86/bin/avbtool"),
            to: candidate.appending("libexec/android-tools/avbtool"),
            files: context.files)
        try copyRegularFile(
            from: appArmorPolicy,
            to: candidate.appending(
                "share/nucleus/android/lxc-nucleus-android.apparmor"),
            files: context.files)
        try copyRegularFile(
            from: seccompPolicy,
            to: candidate.appending(
                "share/nucleus/android/nucleus-android.seccomp"),
            files: context.files)

        let verificationKey = candidate.appending(
            "share/nucleus/android/avb-release-key.pem")
        try await requireSuccess(
            CommandSpec(
                executable: .named("openssl"),
                arguments: [
                    "pkey", "-in", aospSigningKey.string, "-pubout", "-out",
                    verificationKey.string,
                ],
                workingDirectory: candidate,
                environment: environment),
            context: context)
        try await requireSuccess(
            CommandSpec(
                executable: .path(
                    candidate.appending("libexec/android-tools/avbtool")),
                arguments: [
                    "verify_image", "--image",
                    aospGeneration.appending("images/vbmeta.img").string,
                    "--key", verificationKey.string,
                    "--follow_chain_partitions",
                ],
                workingDirectory: candidate,
                environment: environment),
            context: context)

        let payload = try payloadFiles(in: candidate, files: context.files)
        let manifest = try AndroidPackageManifest(
            release: provenance.release,
            buildNumber: provenance.buildNumber,
            architecture: buildArchitecture,
            payload: payload)
        let manifestPath = candidate.appending("package-manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Array(try encoder.encode(manifest))
        bytes.append(0x0a)
        try context.files.write(bytes, to: manifestPath)
        try context.files.move(from: candidate, to: output)
    }

    private var currentArchitecture: AndroidPackageArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        #error("Nucleus supports Android packages only on arm64 and x86_64")
        #endif
    }

    private func requireDirectory(
        _ path: FilePath,
        files: ActionFileSystem
    ) throws {
        guard
            try files.metadataWithoutFollowingSymlinks(for: path)?.type
                == .directory
        else {
            throw AndroidPackageInputFailure(
                "required directory is unavailable: \(path)")
        }
    }

    private func copyRegularFile(
        from source: FilePath,
        to destination: FilePath,
        files: ActionFileSystem
    ) throws {
        guard
            try files.metadataWithoutFollowingSymlinks(for: source)?.type
                == .regular
        else {
            throw AndroidPackageInputFailure(
                "required regular file is unavailable: \(source)")
        }
        try files.copy(from: source, to: destination)
    }

    private func copyPortableAVBTool(
        from source: FilePath,
        to destination: FilePath,
        files: ActionFileSystem
    ) throws {
        let bytes = try files.read(source)
        guard let newline = bytes.firstIndex(of: 0x0a),
            let firstLine = String(bytes: bytes[..<newline], encoding: .utf8),
            firstLine.hasPrefix("#!"),
            firstLine.contains("python")
        else {
            throw AndroidPackageInputFailure(
                "AOSP avbtool must be an architecture-neutral Python script: \(source)")
        }
        try files.write(bytes, to: destination)
        try files.setPermissions(0o555, for: destination)
    }

    private func payloadFiles(
        in root: FilePath,
        files: ActionFileSystem
    ) throws -> [AndroidPackagePayloadFile] {
        var payload: [AndroidPackagePayloadFile] = []
        for entry in try files.listRecursively(root) {
            guard entry.metadata.type != .symbolicLink else {
                throw AndroidPackageInputFailure(
                    "payload cannot contain symlinks: \(entry.path)")
            }
            if entry.metadata.type == .directory { continue }
            guard entry.metadata.type == .regular else {
                throw AndroidPackageInputFailure(
                    "payload contains a non-regular file: \(entry.path)")
            }
            payload.append(
                try AndroidPackagePayloadFile(
                    path: entry.relativePath,
                    size: entry.metadata.size,
                    sha256: hex(try files.digest(file: entry.path).bytes),
                    executable: entry.metadata.permissions & 0o111 != 0))
        }
        return payload.sorted { $0.path < $1.path }
    }

    private func requireSuccess(
        _ command: CommandSpec,
        context: ActionContext
    ) async throws {
        let result = try await context.commands.execute(command)
        guard result.succeeded else {
            throw result.executionFailure(
                reason: "Android package packaging command failed: \(result.standardOutput)")
        }
    }
}

private func hex(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var result: [UInt8] = []
    for byte in bytes {
        result.append(digits[Int(byte >> 4)])
        result.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: result, as: UTF8.self)
}

struct AndroidPackageInputFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = "Android package packaging failed: \(description)"
    }
}
#endif
