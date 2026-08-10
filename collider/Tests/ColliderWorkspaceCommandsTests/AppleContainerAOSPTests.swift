#if os(macOS)
import ColliderCore
import ColliderWorkspaceCommands
import Foundation
import SystemPackage
import Testing

@testable import AndroidRuntimeColliderRecipe
@testable import ColliderAppleContainer
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
        sourceProvenance: path("source-provenance.json"),
        artifactRoot: path("build"),
        outputWorkspace: aospOutputWorkspace(apiLevel: 37),
        compilerCacheWorkspace: aospCompilerCacheWorkspace(apiLevel: 37),
        buildImageID: FilePath(imageID.path),
        artifactImageID: FilePath(imageID.path),
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
        writableMounts: [(path("output"), "/output")],
        readOnlyMounts: aospProductSourceMounts(build: build),
        persistentWorkspaceMounts: [build.outputMount, build.compilerCacheMount],
        command: ["/bin/true"],
        mode: .build,
        containerEnvironment: ["TZ": "UTC"])
    let runtimeConfiguration = nucleusOCIRuntimeConfiguration(
        workspaceRoot: FilePath(root.path))
    let flags = try appleContainerFlags(
        execution,
        name: appleContainerName(for: execution),
        temporaryDirectory: nil,
        configuration: runtimeConfiguration,
        persistentWorkspaceNames: [
            build.outputWorkspace.identity: "aosp-output-volume",
            build.compilerCacheWorkspace.identity: "aosp-ccache-volume",
        ])

    #expect(execution.executionPlatform == .linuxARM64OCI)
    #expect(execution.intelBinaryTranslationPolicy == .required)
    #expect(execution.artifactTarget == .androidX86_64(apiLevel: 37))
    #expect(execution.processFilesystemPolicy == .unmasked)
    #expect(execution.command == ["aosp-build", "/bin/true"])
    #expect(flags.management.entrypoint == nil)
    #expect(aospProductContainerToolEnvironment()["REPO_TRACE"] == "0")
    #expect(
        flags.management.networks
            == [runtimeConfiguration.isolatedNetwork])
    #expect(flags.management.capDrop == ["ALL"])
    #expect(flags.management.readOnly)
    #expect(flags.management.tmpFs.contains("/tmp"))
    #expect(flags.management.tmpFs.contains("/home/nucleus-build"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(path("source").string),target=/src,readonly"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(build.assembledProductSource.string),target=/src/device/nucleus/nucleus_x86_64,readonly"
        ))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(path("output").string),target=/output"))
    #expect(
        flags.management.volumes
            == ["aosp-output-volume:/src/out", "aosp-ccache-volume:/ccache"])
    #expect(
        !flags.process.env.contains(where: {
            $0.contains("SSH_AUTH_SOCK") || $0.contains("WAYLAND_DISPLAY")
        }))

    let toolsExecution = aospProductOCIExecution(
        build: build,
        writableMounts: [],
        readOnlyMounts: [(build.source, "/src")],
        persistentWorkspaceMounts: [build.readOnlyOutputMount],
        command: ["/bin/true"])
    #expect(toolsExecution.command == ["aosp-tools", "/bin/true"])

    let entrypointOverride = aospProductOCIExecution(
        build: build,
        writableMounts: [],
        readOnlyMounts: [],
        command: ["-c", "true"],
        imageEntrypointOverride: "/bin/bash")
    let entrypointOverrideFlags = try appleContainerFlags(
        entrypointOverride,
        name: appleContainerName(for: entrypointOverride),
        temporaryDirectory: nil,
        configuration: runtimeConfiguration)
    #expect(entrypointOverride.command == ["-c", "true"])
    #expect(entrypointOverrideFlags.management.entrypoint == "/bin/bash")
}
#endif
