#if os(macOS)

import ColliderAppleContainer
import ColliderCore
import ColliderRuntime
import Foundation
import SourceImageAssembly
import SystemPackage
import Testing

/// Attaches a built image to a container and reads it from inside Linux.
///
/// Everything else about the image is established by reading it back on the
/// host with the same library that wrote it, which cannot show that a guest
/// kernel agrees. This can: it mounts the image the way a consumer will and
/// asks the kernel what it holds.
///
/// Opt in with `COLLIDER_RUN_APPLE_CONTAINER_INTEGRATION_TESTS=1` and name an
/// image to run in with `COLLIDER_APPLE_CONTAINER_TEST_IMAGE`.
///
/// It will not run under `swift test` from an interactive account. The
/// container service lives in the builder's domain, so a test process started
/// by anyone else reaches it as `XPC connection error: Connection invalid`
/// however healthy the service is. Reaching it means executing as the builder,
/// which is what running a task graph does and what running a test bundle by
/// hand does not. That makes this the wrong shape for the verification it
/// performs: what it asks belongs in a task the sweep runs, and this remains
/// only for an operator who is already executing as the builder.
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment[
            "COLLIDER_RUN_APPLE_CONTAINER_INTEGRATION_TESTS"] == "1"))
func aGuestKernelReadsTheImageTheHostBuilt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "source-image-attach-\(UUID().uuidString)")
    let tree = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(
        at: tree.appendingPathComponent("nested"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("portable contents\n".utf8).write(
        to: tree.appendingPathComponent("readable"))
    try Data("#!/bin/sh\nexit 0\n".utf8).write(
        to: tree.appendingPathComponent("executable"))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: tree.appendingPathComponent("executable").path)
    try FileManager.default.createSymbolicLink(
        atPath: tree.appendingPathComponent("relative-link").path,
        withDestinationPath: "readable")
    try FileManager.default.linkItem(
        atPath: tree.appendingPathComponent("readable").path,
        toPath: tree.appendingPathComponent("nested/hardlink").path)

    let image = FilePath(root.appendingPathComponent("source.img").path)
    try SourceTreeImage.write(tree: FilePath(tree.path), to: image)
    let imageBytes =
        (try FileManager.default.attributesOfItem(atPath: image.string)[.size]
        as? NSNumber)?.uint64Value ?? 0

    let configuration = OCIRuntimeConfiguration(
        isolatedNetwork: "nucleus-build-internal",
        guestHome: "/home/collider-integration",
        managedLabels: ["dev.nucleus.collider.integration=true"],
        managedLabelNamespace: "dev.nucleus.collider.integration",
        persistentWorkspaceOwner: String(repeating: "c", count: 64),
        loggerLabel: "dev.nucleus.collider.integration")
    let declaration = PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            // Fixed, so repeated runs reconcile one volume rather than
            // accumulating a new one each time. The image path changes every
            // run, so each does exercise the rebuild path.
            key: "source-image-attachment",
            artifactTarget: nil,
            role: "source"),
        capacityBytes: imageBytes,
        filesystem: .ext4,
        journal: .writeback64MiB,
        sourceImage: image)
    let mount = OCIPersistentWorkspaceMount(
        workspace: declaration, target: "/source", access: .readOnly)

    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: FilePath("/fixture/image-id"),
        hostname: "collider-source-image",
        workingDirectory: "/source",
        hostWorkingDirectory: FilePath("/fixture"),
        mounts: [],
        persistentWorkspaceMounts: [mount],
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: OCIResourceLimits(
            cpuCount: 2,
            memoryBytes: 1_024 * 1_024 * 1_024,
            processCount: 256),
        containerEnvironment: [:],
        command: [
            "sh", "-c",
            // One line per fact, so a failure names which one disagreed.
            "stat -c %i /source/readable; stat -c %i /source/nested/hardlink; "
                + "stat -c %a /source/executable; readlink /source/relative-link; "
                + "cat /source/readable",
        ],
        environment: [:],
        output: .captured(limit: 64 * 1_024))
    let result = try await AppleContainerRuntimeBackend().execute(
        OCIRuntimeExecutionRequest(
            execution: execution,
            imageReference: ProcessInfo.processInfo.environment[
                "COLLIDER_APPLE_CONTAINER_TEST_IMAGE"]
                ?? "docker.io/library/ubuntu:24.04",
            output: execution.output,
            logging: nil,
            stage: nil,
            cancellation: RuntimeCancellation(),
            configuration: configuration))

    #expect(result.result.succeeded)
    let lines = result.result.standardOutput
        .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    try #require(lines.count == 5, "guest reported \(lines.count) facts: \(lines)")
    // The guest kernel resolves both names to one inode, which is the claim the
    // host-side reading cannot make on the kernel's behalf.
    #expect(lines[0] == lines[1], "the guest sees two inodes, not one file")
    #expect(lines[2] == "755")
    #expect(lines[3] == "readable")
    #expect(lines[4] == "portable contents")
}

#endif
