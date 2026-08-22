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
        deviceSource: path("device"),
        sourceProvenance: path("source-provenance.json"),
        artifactRoot: path("build"),
        sourceWorkspace: aospSourceWorkspace(apiLevel: 37),
        outputWorkspace: aospOutputWorkspace(apiLevel: 37),
        compilerCacheWorkspace: aospCompilerCacheWorkspace(apiLevel: 37),
        buildEntrypoint: try fixtureMountedEntrypoint(
            imageID: FilePath(imageID.path), role: "aosp-build"),
        artifactEntrypoint: try fixtureMountedEntrypoint(
            imageID: FilePath(imageID.path), role: "aosp-artifact"),
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
        readOnlyMounts: aospDeviceSourceMounts(build: build),
        persistentWorkspaceMounts: [build.outputMount, build.compilerCacheMount],
        executableRequirements: aospX86ExecutableRequirements([
            "/out/host/linux-x86/bin/fixture"
        ]),
        command: ["/bin/true"],
        phase: .build,
        containerEnvironment: ["TZ": "UTC"])
    let runtimeConfiguration = nucleusOCIRuntimeConfiguration(
        workspaceRoot: FilePath(root.path))
    let flags = try appleContainerFlags(
        execution,
        name: appleContainerName(for: execution),
        configuration: runtimeConfiguration,
        persistentWorkspaceNames: [
            build.sourceWorkspace.identity: "aosp-source-volume",
            build.outputWorkspace.identity: "aosp-output-volume",
            build.compilerCacheWorkspace.identity: "aosp-ccache-volume",
        ])

    #expect(execution.executionPlatform == .linuxARM64OCI)
    #expect(
        execution.executableRequirements
            == aospX86ExecutableRequirements([
                "/out/host/linux-x86/bin/fixture"
            ]))
    #expect(execution.artifactTarget == .androidX86_64(apiLevel: 37))
    #expect(execution.processFilesystemPolicy == .unmasked)
    #expect(execution.command == ["/bin/true"])
    #expect(
        flags.management.entrypoint
            == "/collider-entrypoints/aosp-build/sh")
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
            "type=bind,source=\(build.assembledDeviceSource.string),target=/src/device/nucleus,readonly"
        ))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(path("output").string),target=/output"))
    #expect(
        flags.management.volumes
            == [
                "aosp-source-volume:/src:ro", "aosp-output-volume:/out",
                "aosp-ccache-volume:/ccache",
            ])
    #expect(
        !flags.process.env.contains(where: {
            $0.contains("SSH_AUTH_SOCK") || $0.contains("WAYLAND_DISPLAY")
        }))

    let toolsExecution = aospProductOCIExecution(
        build: build,
        writableMounts: [],
        readOnlyMounts: [],
        persistentWorkspaceMounts: [build.readOnlyOutputMount],
        command: ["/bin/true"])
    #expect(toolsExecution.command == ["/bin/true"])
}
#endif
