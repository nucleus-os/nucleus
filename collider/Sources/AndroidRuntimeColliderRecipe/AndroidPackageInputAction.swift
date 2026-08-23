import ColliderCore
import SystemPackage

/// One architecture's Android native-package input, as the graph declares it.
///
/// Every field is derived from the recipe context and the locked AOSP product.
/// Nothing here is supplied by a caller: the input is a graph product, and the
/// cohort that consumes it names the producing task rather than a path.
struct AndroidPackageInput {
    /// The architecture the packaged Android payload is for.
    ///
    /// Not the architecture running the materialization: an arm64 builder
    /// packages whichever AOSP product the generation holds, and the
    /// provenance check inside the materialization is what confirms the two
    /// agree.
    let architecture: PlatformArchitecture
    let runtimeSwiftPM: SwiftPMInvocation
    let assemblerSwiftPM: SwiftPMInvocation
    let runtimeScratch: FilePath
    /// The sysroot the payload is assembled from, for the architecture it
    /// packages rather than for the image running the assembly.
    let targetLibraryRoots: [FilePath]
    let aospGeneration: ArtifactReference
    let signingIdentity: ArtifactReference
    let output: FilePath
    let appArmorPolicy: FilePath
    let seccompPolicy: FilePath
    let placement: IdentityPathMap
    let environment: [String: String]

    /// The AVB key the materialization derives a public half from to verify
    /// the chain the AOSP build already signed.
    var aospSigningKey: FilePath {
        signingIdentity.path.appending("releasekey.pem")
    }
}

extension AndroidRuntimeColliderRecipe {
    struct PreparedPackageInput {
        let task: TaskDeclaration
        let artifact: ArtifactReference
    }

    static func packageInputTask(
        _ input: AndroidPackageInput,
        repositoryRoot: FilePath
    ) throws -> PreparedPackageInput {
        let productNames = [
            "nucleus-android-runtime",
            "nucleus-android-runtime-privileged",
            "nucleus-android-gfxstream-broker",
            "nucleus-android-display-host",
        ]
        var products = productNames.map { product in
            input.runtimeSwiftPM.product(
                package: "nucleus",
                product: product,
                packageRoot: repositoryRoot,
                environment: input.environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: input.runtimeSwiftPM.executable(product),
                        validation: .executableFile)
                ])
        }
        let tool = "nucleus-android-assembler"
        products.append(
            input.assemblerSwiftPM.product(
                package: "collider-cli",
                product: tool,
                packageRoot: input.assemblerSwiftPM.context.packageRoot,
                environment: input.environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: input.assemblerSwiftPM.executable(tool),
                        validation: .executableFile)
                ]))
        let inputs: [ArtifactInput] = [
            .file(input.appArmorPolicy),
            .file(input.seccompPolicy),
            input.runtimeSwiftPM.identityInput,
            input.assemblerSwiftPM.identityInput,
        ]
        var builder = TaskBuilder(
            id: AndroidRuntimeTaskIDs.packageInput(input.architecture),
            component: descriptor.id)
        builder.consume(input.aospGeneration)
        builder.consume(input.signingIdentity)
        let artifact: ArtifactReference = try builder.output(
            "package-input",
            path: input.output,
            validation: .nonEmptyDirectory)
        return PreparedPackageInput(
            task: builder.build(
                swiftProducts: products,
                inputs: inputs,
                locks: [
                    .shared(
                        input.output.removingLastComponent().appending(
                            ".android-package-input.lock"))
                ],
                action: try packageInputAction(input)),
            artifact: artifact)
    }

    /// The materialization runs inside the builder image on every host. A
    /// native action is admitted only on a runner whose operating system
    /// matches it, so on the macOS builder this is the only route: without it
    /// the one Android step nothing containerized could not be planned at all,
    /// and the package cohort that depends on it could not be assembled.
    private static func packageInputAction(
        _ input: AndroidPackageInput
    ) throws -> AnyColliderAction {
        try AnyColliderAction(
            PublishAndroidPackageInputAction(
                runtimeSwiftPM: input.runtimeSwiftPM,
                assemblerSwiftPM: input.assemblerSwiftPM,
                architecture: input.architecture,
                targetLibraryRoots: input.targetLibraryRoots,
                aospGeneration: input.aospGeneration.path,
                aospSigningKey: input.aospSigningKey,
                runtimeScratch: input.runtimeScratch,
                output: input.output,
                appArmorPolicy: input.appArmorPolicy,
                seccompPolicy: input.seccompPolicy,
                placement: input.placement,
                environment: input.environment))
    }
}

#if os(Linux)
import Foundation
import NucleusAndroidRuntimeCore
import ShellColliderRecipe

package struct MaterializeAndroidPackageInputAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let runtimeProducts: FilePath
        let runtimeScratch: FilePath
        let aospGeneration: FilePath
        let aospSigningKey: FilePath
        let output: FilePath
        let appArmorPolicy: FilePath
        let seccompPolicy: FilePath
        let architecture: PlatformArchitecture
        let targetLibraryRoots: [FilePath]

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: runtimeProducts)
            encoder.append(path: runtimeScratch)
            encoder.append(path: aospGeneration)
            encoder.append(path: aospSigningKey)
            encoder.append(path: output)
            encoder.append(path: appArmorPolicy)
            encoder.append(path: seccompPolicy)
            encoder.appendEnum(architecture)
            // The sysroot the payload is assembled from decides what it ships.
            encoder.appendSequence(targetLibraryRoots) { $0.append(path: $1) }
        }
    }

    package static let kind: ActionKind = "android-runtime.package-input"

    let runtimeProducts: FilePath
    let runtimeScratch: FilePath
    let aospGeneration: FilePath
    let aospSigningKey: FilePath
    let output: FilePath
    let appArmorPolicy: FilePath
    let seccompPolicy: FilePath
    let architecture: PlatformArchitecture
    let targetLibraryRoots: [FilePath]
    package let environment: [String: String]

    package var identity: Identity {
        Identity(
            runtimeProducts: runtimeProducts,
            runtimeScratch: runtimeScratch,
            aospGeneration: aospGeneration,
            aospSigningKey: aospSigningKey,
            output: output,
            appArmorPolicy: appArmorPolicy,
            seccompPolicy: seccompPolicy,
            architecture: architecture,
            targetLibraryRoots: targetLibraryRoots)
    }

    package var requirements: ActionRequirements {
        let effects = [
            ActionEffect(.read, scope: .input(runtimeProducts)),
            ActionEffect(.read, scope: .input(aospGeneration)),
            ActionEffect(.read, scope: .input(aospSigningKey)),
            ActionEffect(.read, scope: .checkout(appArmorPolicy)),
            ActionEffect(.read, scope: .checkout(seccompPolicy)),
            ActionEffect(.read, scope: .unrestricted(FilePath("/"))),
            ActionEffect(.readWrite, scope: .scratch(runtimeScratch)),
            ActionEffect(.readWrite, scope: .output(output.removingLastComponent())),
        ]
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "avbtool",
                    executable: .path(
                        aospGeneration.appending("tools/avbtool")),
                    role: .semantic),
                // The published AVB tool is a Python script, so the
                // interpreter its shebang names is an input to this
                // materialization rather than an incidental part of the image.
                ActionToolRequirement(
                    "python3", executable: .named("python3"), role: .semantic),
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

    /// The fields the materialization actually reads, for the tool that
    /// re-enters it inside a container with paths named as the container sees
    /// them rather than as a recipe configured them.
    package init(
        runtimeProducts: FilePath,
        runtimeScratch: FilePath,
        aospGeneration: FilePath,
        aospSigningKey: FilePath,
        architecture: PlatformArchitecture,
        targetLibraryRoots: [FilePath],
        output: FilePath,
        appArmorPolicy: FilePath,
        seccompPolicy: FilePath,
        environment: [String: String]
    ) {
        self.runtimeProducts = runtimeProducts
        self.runtimeScratch = runtimeScratch
        self.aospGeneration = aospGeneration
        self.aospSigningKey = aospSigningKey
        self.architecture = architecture
        self.targetLibraryRoots = targetLibraryRoots
        self.output = output
        self.appArmorPolicy = appArmorPolicy
        self.seccompPolicy = seccompPolicy
        self.environment = environment
    }

    package func execute(in context: ActionContext) async throws {
        // A declared output the graph re-materializes whenever the generation
        // or the runtime products change, so an earlier materialization is
        // replaced rather than treated as a conflict.
        try context.files.createDirectory(output.removingLastComponent())
        try context.files.remove(output)
        try context.files.createDirectory(runtimeScratch)
        let candidate = runtimeScratch.appending("package-input-candidate")
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        defer { try? context.files.remove(candidate) }

        let buildArchitecture = architecture

        // Scratch the candidate is copied out of, so it is removed when this
        // materialization returns. Deferring inside the staging block instead
        // would delete the tree at the end of that block, before anything read
        // it.
        let stagedRuntime = runtimeScratch.appending("runtime")
        try context.files.remove(stagedRuntime)
        defer { try? context.files.remove(stagedRuntime) }
        try await stageRuntimeELF(
            products: runtimeProducts,
            prefix: stagedRuntime,
            targetLibraryRoots: targetLibraryRoots,
            environment: environment,
            productSet: .androidPackage,
            targetArchitecture: buildArchitecture,
            context: context)

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
            stagedRuntime.appending("lib"),
            files: context.files)
        try context.files.copyTree(
            from: stagedRuntime.appending("lib"),
            to: candidate.appending("lib"))
        for executable in [
            "nucleus-android-runtime",
            "nucleus-android-runtime-privileged",
            "nucleus-android-gfxstream-broker",
            "nucleus-android-display-host",
        ] {
            try copyRegularFile(
                from: stagedRuntime.appending("libexec/\(executable)"),
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
            from: aospGeneration.appending("tools/avbtool"),
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
            architecture: packageArchitecture(buildArchitecture),
            payload: payload)
        let manifestPath = candidate.appending("package-manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Array(try encoder.encode(manifest))
        bytes.append(0x0a)
        try context.files.write(bytes, to: manifestPath)
        try context.files.move(from: candidate, to: output)
    }

    private func packageArchitecture(
        _ architecture: PlatformArchitecture
    ) -> AndroidPackageArchitecture {
        switch architecture {
        case .arm64: .arm64
        case .x86_64: .x86_64
        }
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
