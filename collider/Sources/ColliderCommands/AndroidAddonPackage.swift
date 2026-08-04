#if os(Linux)
import ColliderCore
import ColliderRuntime
import Foundation
import NucleusAndroidRuntimeCore
import ShellColliderRecipe
import SystemPackage

struct AndroidAddonPackageCommand {
    let context: WorkspaceContext

    func run(
        runtimeRoot explicitRuntimeRoot: URL?,
        aospGeneration: URL,
        compatibilityURL: URL,
        aospSigningKey: URL,
        addonSigningKey: URL,
        output: URL
    ) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw WorkspaceFailure.message(
                "Android add-on output already exists: \(output.path)")
        }
        let parent = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
        let candidate = parent.appendingPathComponent(
            ".\(output.lastPathComponent).candidate-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: candidate, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: candidate) }

        let compatibility = try JSONDecoder().decode(
            AndroidAddonCompatibility.self,
            from: Data(contentsOf: compatibilityURL))
        #if arch(arm64)
        let buildArchitecture = AndroidAddonArchitecture.arm64
        #elseif arch(x86_64)
        let buildArchitecture = AndroidAddonArchitecture.x86_64
        #else
        #error("Nucleus supports Android add-ons only on arm64 and x86_64")
        #endif
        guard compatibility.architecture == buildArchitecture else {
            throw WorkspaceFailure.message(
                "Android add-on packaging must run on the target architecture; "
                    + "this process is \(buildArchitecture.rawValue), but the base "
                    + "compatibility declaration is \(compatibility.architecture.rawValue)")
        }
        let generatedRuntimeRoot = context.layout.work.appendingPathComponent(
            "android-addon-runtime-\(UUID().uuidString)", isDirectory: true)
        let runtimeRoot: URL
        if let explicitRuntimeRoot {
            runtimeRoot = explicitRuntimeRoot
        } else {
            runtimeRoot = generatedRuntimeRoot
            try await stageRuntime(at: runtimeRoot)
        }
        defer {
            if explicitRuntimeRoot == nil {
                try? FileManager.default.removeItem(at: generatedRuntimeRoot)
            }
        }
        let provenanceURL = aospGeneration.appendingPathComponent(
            "signed/image-provenance.json")
        let provenance = try JSONDecoder().decode(
            AndroidImageProvenance.self,
            from: Data(contentsOf: provenanceURL))
        let expectedProduct =
            switch compatibility.architecture {
            case .arm64: "nucleus_arm64"
            case .x86_64: "nucleus_x86_64"
            }
        guard provenance.status == "signed", provenance.product == expectedProduct else {
            throw WorkspaceFailure.message(
                "signed AOSP product \(provenance.product) does not match "
                    + "\(compatibility.architecture.rawValue)")
        }
        let requiredImages = Set([
            "system.img", "system_ext.img", "product.img", "vendor.img",
            "vbmeta.img", "vbmeta_system.img",
        ])
        guard Set(provenance.images.map(\.name)) == requiredImages,
            provenance.images.allSatisfy({ $0.storageFormat == "raw" })
        else {
            throw WorkspaceFailure.message(
                "signed AOSP provenance does not declare the complete raw image set")
        }

        try copyTree(
            runtimeRoot.appendingPathComponent("lib"), to: candidate.appendingPathComponent("lib"))
        for executable in [
            "nucleus-android-runtime",
            "nucleus-android-runtime-privileged",
            "nucleus-android-gfxstream-broker",
            "nucleus-android-display-host",
        ] {
            try copyRegularFile(
                runtimeRoot.appendingPathComponent("libexec/\(executable)"),
                to: candidate.appendingPathComponent("libexec/\(executable)"))
        }
        try copyRegularFile(
            provenanceURL,
            to: candidate.appendingPathComponent("image-provenance.json"))
        for image in provenance.images {
            let source = aospGeneration.appendingPathComponent(
                "images/\(image.name)")
            let values = try source.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard let size = values.fileSize, size >= 0,
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                UInt64(size) == image.size,
                hex(try ArtifactHasher.digest(file: FilePath(source.path)).bytes)
                    == image.sha256
            else {
                throw WorkspaceFailure.message(
                    "signed AOSP image does not match provenance: \(image.name)")
            }
            try copyRegularFile(
                source,
                to: candidate.appendingPathComponent("images/\(image.name)"))
        }
        try copyPortableAVBTool(
            aospGeneration.appendingPathComponent("out/host/linux-x86/bin/avbtool"),
            to: candidate.appendingPathComponent("libexec/android-tools/avbtool"))
        try copyRegularFile(
            context.layout.androidRuntime.appendingPathComponent(
                "container/lxc-nucleus-android.apparmor"),
            to: candidate.appendingPathComponent(
                "share/nucleus/android/lxc-nucleus-android.apparmor"))
        try copyRegularFile(
            context.layout.androidRuntime.appendingPathComponent(
                "container/nucleus-android.seccomp"),
            to: candidate.appendingPathComponent(
                "share/nucleus/android/nucleus-android.seccomp"))
        let verificationKey = candidate.appendingPathComponent(
            "share/nucleus/android/avb-release-key.pem")
        try FileManager.default.createDirectory(
            at: verificationKey.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try await context.run(
            "openssl",
            [
                "pkey", "-in", aospSigningKey.path, "-pubout", "-out",
                verificationKey.path,
            ])
        try await context.run(
            candidate.appendingPathComponent("libexec/android-tools/avbtool").path,
            [
                "verify_image", "--image",
                aospGeneration.appendingPathComponent("images/vbmeta.img").path,
                "--key", verificationKey.path,
                "--follow_chain_partitions",
            ])

        let payload = try payloadFiles(in: candidate)
        let manifest = try AndroidAddonManifest(
            release: provenance.release,
            buildNumber: provenance.buildNumber,
            architecture: compatibility.architecture,
            requiredNucleusBuildIdentity: compatibility.nucleusBuildIdentity,
            requiredKernelCapabilityIdentity: compatibility.kernelCapabilityIdentity,
            payload: payload)
        let manifestURL = candidate.appendingPathComponent("addon-manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Array(try encoder.encode(manifest))
        bytes.append(0x0a)
        try Data(bytes).write(to: manifestURL, options: .atomic)
        try await context.run(
            "openssl",
            [
                "dgst", "-sha256", "-sign", addonSigningKey.path, "-out",
                candidate.appendingPathComponent("addon-manifest.json.sig").path,
                manifestURL.path,
            ])
        try FileManager.default.moveItem(at: candidate, to: output)
        print("packaged signed Android add-on → \(output.path)")
    }

    private func stageRuntime(at destination: URL) async throws {
        let swiftPM = try context.swiftPMInvocation(configuration: .release)
        for product in [
            "nucleus-android-runtime",
            "nucleus-android-runtime-privileged",
            "nucleus-android-gfxstream-broker",
            "nucleus-android-display-host",
        ] {
            try await context.run(
                "swift",
                swiftPM.commandArguments(["build", "--product", product]),
                environmentOverrides: swiftPM.commandEnvironment(
                    context.taskEnvironment))
        }
        try await context.runtime.execute(
            StageRuntimeELFAction(
                products: swiftPM.configurationProducts,
                prefix: FilePath(destination.path),
                environment: context.taskEnvironment,
                productSet: .androidAddon))
    }

    private func payloadFiles(in root: URL) throws -> [AndroidAddonPayloadFile] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
        else {
            throw WorkspaceFailure.message(
                "could not enumerate Android add-on payload: \(root.path)")
        }
        var result: [AndroidAddonPayloadFile] = []
        while let path = enumerator.nextObject() as? URL {
            let values = try path.resourceValues(
                forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
            guard values.isSymbolicLink != true else {
                throw WorkspaceFailure.message(
                    "Android add-on payload cannot contain symlinks: \(path.path)")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw WorkspaceFailure.message(
                    "Android add-on payload contains a non-regular file: \(path.path)")
            }
            let relative = String(path.path.dropFirst(root.path.count + 1))
            let attributes = try FileManager.default.attributesOfItem(
                atPath: path.path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber else {
                throw WorkspaceFailure.message(
                    "could not read Android add-on payload permissions: \(path.path)")
            }
            result.append(
                try AndroidAddonPayloadFile(
                    path: relative,
                    size: UInt64(size),
                    sha256: hex(
                        try ArtifactHasher.digest(file: FilePath(path.path)).bytes),
                    executable: permissions.uint16Value & 0o111 != 0))
        }
        return result
    }

    private func copyTree(_ source: URL, to destination: URL) throws {
        let values = try source.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw WorkspaceFailure.message(
                "required Android add-on directory is unavailable: \(source.path)")
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func copyRegularFile(_ source: URL, to destination: URL) throws {
        let values = try source.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WorkspaceFailure.message(
                "required Android add-on input is unavailable: \(source.path)")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func copyPortableAVBTool(_ source: URL, to destination: URL) throws {
        let resolved = source.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
        let bytes = try Data(contentsOf: resolved)
        guard values.isRegularFile == true,
            let firstLine = String(
                data: bytes.prefix { $0 != 0x0a }, encoding: .utf8),
            firstLine.hasPrefix("#!"),
            firstLine.contains("python")
        else {
            throw WorkspaceFailure.message(
                "AOSP avbtool must be an architecture-neutral Python script: \(source.path)")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try bytes.write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: destination.path)
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
}
#endif
