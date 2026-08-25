import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ColliderCore

@Test func aContainerReachesOnlyWhatItsActionDeclares() async throws {
    let reached = Mutex<[FilePath]>([])
    let declared = ActionRequirements(
        effects: [
            ActionEffect(.read, scope: .input(FilePath("/inputs/image-id"))),
            ActionEffect(.read, scope: .checkout(FilePath("/checkout/core"))),
        ],
        lane: .oci,
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64)
    let containers = ActionContainerExecutor(
        run: { execution in
            reached.withLock { $0 += execution.mounts.map(\.source) }
            return CommandResult(status: 0)
        }
    ).scoped(to: declared)

    // A tree the action declared is a tree it may mount.
    try await containers.run(
        fixtureExecution(mounting: [FilePath("/checkout/core/swift-core")]))
    #expect(reached.withLock { $0 } == [FilePath("/checkout/core/swift-core")])

    // A tree it did not declare is not, and the container never starts.
    await #expect(throws: ActionContainerScopeFailure.self) {
        try await containers.run(
            fixtureExecution(mounting: [FilePath("/checkout/react-native")]))
    }
    #expect(reached.withLock { $0 } == [FilePath("/checkout/core/swift-core")])

    // Reading a tree is not writing it.
    await #expect(throws: ActionContainerScopeFailure.self) {
        try await containers.run(
            fixtureExecution(
                exporting: [FilePath("/checkout/core/swift-core/generated")]))
    }
}

@Test func aPipelineActionDeclaresWhatItMounts() async throws {
    let execution = fixtureExecution(mounting: [FilePath("/checkout/core")])
    let pipeline = try OCIExecutionPipeline([execution])
    let ran = Mutex(false)
    let containers = ActionContainerExecutor(
        run: { _ in
            ran.withLock { $0 = true }
            return CommandResult(status: 0)
        }
    ).scoped(to: pipeline.requirements)

    // An action that is its pipeline derives its declaration from the same
    // executions, so the boundary holds without the action restating it.
    try await containers.run(execution)
    #expect(ran.withLock { $0 })
}

@Test func aWorkspaceDeclarationBoundsHowMuchOfItIsMounted() async throws {
    let workspace = fixtureWorkspace()
    let declared = ActionRequirements(
        effects: [ActionEffect(.read, scope: .input(FilePath("/inputs/image-id")))],
        persistentWorkspaceEffects: [
            ActionPersistentWorkspaceEffect(
                workspace: workspace,
                target: "/src",
                access: .readWrite)
        ],
        lane: .oci,
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64)
    let containers = ActionContainerExecutor(
        run: { _ in CommandResult(status: 0) }
    ).scoped(to: declared)

    // Mounting less of a workspace than was declared stays within the
    // declaration. Mounting it somewhere else does not.
    try await containers.run(
        fixtureExecution(
            attaching: [
                OCIPersistentWorkspaceMount(
                    workspace: workspace,
                    target: "/src",
                    access: .readOnly)
            ]))
    await #expect(throws: ActionContainerScopeFailure.self) {
        try await containers.run(
            fixtureExecution(
                attaching: [
                    OCIPersistentWorkspaceMount(
                        workspace: workspace,
                        target: "/elsewhere",
                        access: .readOnly)
                ]))
    }
}

private func fixtureWorkspace() -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: "container-scope-fixture",
            artifactTarget: .linuxARM64,
            role: "source"),
        capacityBytes: 64 * 1_024 * 1_024 * 1_024,
        filesystem: .ext4,
        journal: .writeback64MiB)
}

private func fixtureExecution(
    mounting readOnly: [FilePath] = [],
    exporting boundedExports: [FilePath] = [],
    attaching workspaces: [OCIPersistentWorkspaceMount] = []
) -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: FilePath("/inputs/image-id"),
        hostname: "fixture",
        workingDirectory: "/workspace",
        hostWorkingDirectory: FilePath("/checkout"),
        mounts: readOnly.map {
            OCIMount(source: $0, target: "/workspace", access: .readOnly)
        }
            + boundedExports.map {
                OCIMount(boundedExport: $0, target: "/exports")
            },
        persistentWorkspaceMounts: workspaces,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .build,
        containerEnvironment: [:],
        command: ["true"],
        environment: [:],
        output: .logged)
}
