#if os(macOS)
import ColliderCore
import ColliderWorkspaceCommands
import Foundation
import SystemPackage
import Testing

@testable import AndroidRuntimeColliderRecipe
@testable import ColliderRuntime

@Test
func aospContainerInvocationHasTheRequiredIsolationBoundary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-aosp-container-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true)
    let imageID = root.appendingPathComponent("image-id")
    try Data(
        ("sha256:" + String(repeating: "a", count: 64) + "\n").utf8
    ).write(to: imageID)
    let path = { (name: String) in
        FilePath(root.appendingPathComponent(name).path)
    }
    let build = AOSPProductBuild(
        productSource: path("product"),
        source: path("source"),
        repoLauncher: path("repo"),
        sourceProvenance: path("source-provenance.json"),
        buildRoot: path("build"),
        ccacheDirectory: path("ccache"),
        containerImageID: FilePath(imageID.path),
        signingIdentity: path("keys"),
        product: "nucleus_x86_64",
        release: "cp2a",
        variant: "user",
        buildNumber: "nucleus",
        buildTimestamp: 1,
        buildJobs: 16,
        expectedPlatformSDK: 37,
        expectedVendorAPILevel: 202604,
        environment: [:])

    let execution = aospProductOCIExecution(
        build: build,
        writableMounts: [
            (path("output"), "/output"),
            (path("ccache"), "/src/out/nucleus/.ccache"),
        ],
        readOnlyMounts: [(path("source"), "/src")],
        command: ["/bin/true"],
        containerEnvironment: ["TZ": "UTC"])
    let executor = AppleContainerExecutor()
    let flags = appleContainerFlags(
        execution,
        name: try executor.containerName(for: execution),
        temporaryDirectory: nil,
        configuration: nucleusOCIRuntimeConfiguration)

    #expect(execution.executionPlatform == .linuxARM64OCI)
    #expect(execution.intelBinaryTranslationPolicy == .required)
    #expect(execution.artifactTarget == .androidX86_64(apiLevel: 37))
    #expect(execution.processFilesystemPolicy == .unmasked)
    #expect(
        flags.management.networks
            == [nucleusOCIRuntimeConfiguration.isolatedNetwork])
    #expect(flags.management.capDrop == ["ALL"])
    #expect(flags.management.readOnly)
    #expect(flags.management.tmpFs.contains("/tmp"))
    #expect(flags.management.tmpFs.contains("/home/nucleus-build"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(path("source").string),target=/src,readonly"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(path("output").string),target=/output"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(path("ccache").string),"
                + "target=/src/out/nucleus/.ccache"))
    #expect(
        !flags.process.env.contains(where: {
            $0.contains("SSH_AUTH_SOCK") || $0.contains("WAYLAND_DISPLAY")
        }))
}
#endif
