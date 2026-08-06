#if os(Linux)
import ColliderCore
import ColliderPersistence
import ColliderRuntime
import Foundation
import NucleusAndroidRuntimeCore
import NucleusSessionProtocol
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands
@testable import ColliderLinuxOperations
@testable import AndroidRuntimeColliderRecipe

#if arch(arm64)
private let testAddonArchitecture = AndroidAddonArchitecture.arm64
private let testAOSPProduct = "nucleus_arm64"
#elseif arch(x86_64)
private let testAddonArchitecture = AndroidAddonArchitecture.x86_64
private let testAOSPProduct = "nucleus_x86_64"
#else
#error("Nucleus Android add-on tests require arm64 or x86_64")
#endif

@Test func androidAddonInstallationIsAtomicAndStateSurvivesDeactivation() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "nucleus-android-addon-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let artifact = temporary.appendingPathComponent("artifact", isDirectory: true)
    let base = temporary.appendingPathComponent("base", isDirectory: true)
    let store = temporary.appendingPathComponent("store", isDirectory: true)
    let state = temporary.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: base.appendingPathComponent("share/nucleus", isDirectory: true),
        withIntermediateDirectories: true)

    let requiredFiles: [(String, Bool)] = [
        ("images/system.img", false),
        ("images/system_ext.img", false),
        ("images/product.img", false),
        ("images/vendor.img", false),
        ("images/vbmeta.img", false),
        ("images/vbmeta_system.img", false),
        ("libexec/nucleus-android-runtime", true),
        ("libexec/nucleus-android-runtime-privileged", true),
        ("libexec/nucleus-android-gfxstream-broker", true),
        ("libexec/nucleus-android-display-host", true),
        ("libexec/android-tools/avbtool", true),
        ("share/nucleus/android/avb-release-key.pem", false),
        ("share/nucleus/android/lxc-nucleus-android.apparmor", false),
        ("share/nucleus/android/nucleus-android.seccomp", false),
    ]
    var payload: [AndroidAddonPayloadFile] = []
    var images: [AndroidImageProvenance.Image] = []
    for (relative, executable) in requiredFiles {
        let path = artifact.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes =
            relative == "libexec/android-tools/avbtool"
            ? Data("#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n".utf8)
            : Data("payload:\(relative)".utf8)
        try bytes.write(to: path)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        payload.append(
            try AndroidAddonPayloadFile(
                path: relative,
                size: UInt64(bytes.count),
                sha256: hex(try ArtifactHasher.digest(file: FilePath(path.path)).bytes),
                executable: executable))
        if relative.hasPrefix("images/") {
            images.append(
                AndroidImageProvenance.Image(
                    name: path.lastPathComponent,
                    size: UInt64(bytes.count),
                    storageFormat: "raw",
                    sha256: hex(
                        try ArtifactHasher.digest(file: FilePath(path.path)).bytes)))
        }
    }
    let provenance = AndroidImageProvenance(
        status: "signed",
        product: testAOSPProduct,
        release: "Android 17",
        variant: "user",
        buildNumber: "test-1",
        buildTimestamp: 1,
        platformSDK: 37,
        vendorAPILevel: 202_604,
        sourceManifestCommit: "source",
        sourceSuperprojectCommit: "superproject",
        sourceManifestSHA256: String(repeating: "a", count: 64),
        productTreeSHA256: String(repeating: "b", count: 64),
        images: images)
    let provenanceURL = artifact.appendingPathComponent("image-provenance.json")
    let provenanceBytes = try encodeJSON(provenance)
    try provenanceBytes.write(to: provenanceURL)
    payload.append(
        try AndroidAddonPayloadFile(
            path: "image-provenance.json",
            size: UInt64(provenanceBytes.count),
            sha256: hex(
                try ArtifactHasher.digest(file: FilePath(provenanceURL.path)).bytes)))

    let identity = String(repeating: "1", count: 64)
    let kernel = String(repeating: "2", count: 64)
    let compatibility = try AndroidAddonCompatibility(
        nucleusBuildIdentity: identity,
        kernelCapabilityIdentity: kernel,
        architecture: testAddonArchitecture)
    try encodeJSON(compatibility).write(
        to: base.appendingPathComponent("share/nucleus/android-addon-compatibility.json"))
    let manifest = try AndroidAddonManifest(
        release: "Android 17",
        buildNumber: "test-1",
        architecture: testAddonArchitecture,
        requiredNucleusBuildIdentity: identity,
        requiredKernelCapabilityIdentity: kernel,
        payload: payload)
    let manifestURL = artifact.appendingPathComponent("addon-manifest.json")
    try encodeJSON(manifest).write(to: manifestURL)

    let privateKey = temporary.appendingPathComponent("private.pem")
    let publicKey = temporary.appendingPathComponent("public.pem")
    let signature = artifact.appendingPathComponent("addon-manifest.json.sig")
    let context = WorkspaceContext(
        root: FilePath(temporary.path),
        environment: ["HOME": temporary.path])
    try await context.run(
        "openssl",
        [
            "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
            "-out", privateKey.path,
        ])
    try await context.run(
        "openssl", ["pkey", "-in", privateKey.path, "-pubout", "-out", publicKey.path])
    try await context.run(
        "openssl",
        [
            "dgst", "-sha256", "-sign", privateKey.path, "-out", signature.path,
            manifestURL.path,
        ])

    let command = AndroidAddonInstallCommand()
    try command.install(
        artifact: artifact,
        trustKey: publicKey,
        basePrefix: base,
        storeRoot: store,
        persistentStateRoot: state)

    let active = store.appendingPathComponent("current")
    #expect((try active.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
    let capabilityURL = store.appendingPathComponent("session-capabilities/android.json")
    let capability = try JSONDecoder().decode(
        SessionCapabilityDeclaration.self, from: Data(contentsOf: capabilityURL))
    #expect(
        capability.executable
            == active.appendingPathComponent("libexec/nucleus-android-runtime").path)
    #expect(
        capability.arguments
            == ["--addon-root", store.path, "--state-root", state.path])
    let stateAttributes = try FileManager.default.attributesOfItem(
        atPath: state.path)
    let statePermissions = try #require(
        stateAttributes[.posixPermissions] as? NSNumber)
    #expect(statePermissions.uint16Value == 0o700)
    let retained = state.appendingPathComponent("retained")
    try Data("state".utf8).write(to: retained)

    let activeGeneration = try FileManager.default.destinationOfSymbolicLink(
        atPath: active.path)
    let tampered = temporary.appendingPathComponent(
        "tampered-artifact", isDirectory: true)
    try FileManager.default.copyItem(at: artifact, to: tampered)
    try Data("tampered".utf8).write(
        to: tampered.appendingPathComponent("images/system.img"))
    #expect(throws: (any Error).self) {
        try command.install(
            artifact: tampered,
            trustKey: publicKey,
            basePrefix: base,
            storeRoot: store,
            persistentStateRoot: state)
    }
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
            == activeGeneration)
    #expect(FileManager.default.fileExists(atPath: capabilityURL.path))

    try command.deactivate(storeRoot: store, persistentStateRoot: state)

    #expect(!FileManager.default.fileExists(atPath: active.path))
    #expect(!FileManager.default.fileExists(atPath: capabilityURL.path))
    #expect(FileManager.default.fileExists(atPath: retained.path))

    try command.install(
        artifact: artifact,
        trustKey: publicKey,
        basePrefix: base,
        storeRoot: store,
        persistentStateRoot: state)
    try command.uninstall(storeRoot: store, persistentStateRoot: state)
    #expect(
        !FileManager.default.fileExists(atPath: store.appendingPathComponent("generations").path))
    #expect(FileManager.default.fileExists(atPath: retained.path))
}

@Test func androidAddonPackagingProducesASignedCompleteArtifact() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "nucleus-android-package-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let runtime = temporary.appendingPathComponent("runtime", isDirectory: true)
    let aosp = temporary.appendingPathComponent("aosp", isDirectory: true)
    let output = temporary.appendingPathComponent("output", isDirectory: true)
    let compatibilityURL = temporary.appendingPathComponent("compatibility.json")
    for directory in [
        runtime.appendingPathComponent("lib"),
        runtime.appendingPathComponent("libexec"),
        aosp.appendingPathComponent("images"),
        aosp.appendingPathComponent("signed"),
        aosp.appendingPathComponent("out/host/linux-x86/bin"),
        temporary.appendingPathComponent("android-runtime/container"),
    ] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }
    try Data("library".utf8).write(
        to: runtime.appendingPathComponent("lib/libaddon.so"))
    for executable in [
        "nucleus-android-runtime",
        "nucleus-android-runtime-privileged",
        "nucleus-android-gfxstream-broker",
        "nucleus-android-display-host",
    ] {
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: runtime.appendingPathComponent("libexec/\(executable)"))
    }
    for policy in [
        "lxc-nucleus-android.apparmor", "nucleus-android.seccomp",
    ] {
        try Data("policy".utf8).write(
            to: temporary.appendingPathComponent("android-runtime/container/\(policy)"))
    }
    try writeExecutable(
        "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n",
        to: aosp.appendingPathComponent("out/host/linux-x86/bin/avbtool"))

    var images: [AndroidImageProvenance.Image] = []
    for name in [
        "system.img", "system_ext.img", "product.img", "vendor.img",
        "vbmeta.img", "vbmeta_system.img",
    ] {
        let path = aosp.appendingPathComponent("images/\(name)")
        let bytes = Data("image:\(name)".utf8)
        try bytes.write(to: path)
        images.append(
            AndroidImageProvenance.Image(
                name: name,
                size: UInt64(bytes.count),
                storageFormat: "raw",
                sha256: hex(
                    try ArtifactHasher.digest(file: FilePath(path.path)).bytes)))
    }
    let provenance = AndroidImageProvenance(
        status: "signed",
        product: testAOSPProduct,
        release: "Android 17",
        variant: "user",
        buildNumber: "test-1",
        buildTimestamp: 1,
        platformSDK: 37,
        vendorAPILevel: 202_604,
        sourceManifestCommit: "source",
        sourceSuperprojectCommit: "superproject",
        sourceManifestSHA256: String(repeating: "a", count: 64),
        productTreeSHA256: String(repeating: "b", count: 64),
        images: images)
    try encodeJSON(provenance).write(
        to: aosp.appendingPathComponent("signed/image-provenance.json"))
    let compatibility = try AndroidAddonCompatibility(
        nucleusBuildIdentity: String(repeating: "1", count: 64),
        kernelCapabilityIdentity: String(repeating: "2", count: 64),
        architecture: testAddonArchitecture)
    try encodeJSON(compatibility).write(to: compatibilityURL)

    let aospKey = temporary.appendingPathComponent("aosp-private.pem")
    let addonKey = temporary.appendingPathComponent("addon-private.pem")
    let addonPublicKey = temporary.appendingPathComponent("addon-public.pem")
    let context = WorkspaceContext(
        root: FilePath(temporary.path),
        environment: ["HOME": temporary.path])
    for key in [aospKey, addonKey] {
        try await context.run(
            "openssl",
            [
                "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
                "-out", key.path,
            ])
    }
    try await context.run(
        "openssl",
        ["pkey", "-in", addonKey.path, "-pubout", "-out", addonPublicKey.path])

    let packageRoot = FilePath(temporary.path)
    let swiftPM = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: .release,
            target: .host(identity: "fixture-linux"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: packageRoot.appending("swift-build"))
    let runtimeExecutor = ColliderRuntime()
    try await runtimeExecutor.execute(
        PackageAndroidAddonAction(
            configuration: AndroidAddonPackageConfiguration(
                swiftPM: swiftPM,
                runtimeRoot: FilePath(runtime.path),
                runtimeScratch: packageRoot.appending("runtime-scratch"),
                aospGeneration: FilePath(aosp.path),
                usesManagedAOSPGeneration: false,
                compatibility: FilePath(compatibilityURL.path),
                aospSigningKey: FilePath(aospKey.path),
                addonSigningKey: FilePath(addonKey.path),
                output: FilePath(output.path),
                appArmorPolicy: packageRoot.appending(
                    "android-runtime/container/lxc-nucleus-android.apparmor"),
                seccompPolicy: packageRoot.appending(
                    "android-runtime/container/nucleus-android.seccomp"),
                environment: context.taskEnvironment)))
    await runtimeExecutor.shutdown()

    let manifestURL = output.appendingPathComponent("addon-manifest.json")
    let manifest = try JSONDecoder().decode(
        AndroidAddonManifest.self, from: Data(contentsOf: manifestURL))
    #expect(manifest.architecture == testAddonArchitecture)
    #expect(manifest.payload.contains { $0.path == "lib/libaddon.so" })
    #expect(manifest.payload.contains { $0.path == "images/system.img" })
    #expect(!manifest.payload.contains { $0.path.contains("private") })
    try await context.run(
        "openssl",
        [
            "dgst", "-sha256", "-verify", addonPublicKey.path, "-signature",
            output.appendingPathComponent("addon-manifest.json.sig").path,
            manifestURL.path,
        ])
}

private func encodeJSON(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func writeExecutable(_ contents: String, to path: URL) throws {
    try Data(contents.utf8).write(to: path)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path.path)
}
#endif
