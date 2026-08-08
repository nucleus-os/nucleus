import ColliderCore
import ColliderTesting
import SystemPackage

func ociExecutions(
    in action: AnyColliderAction?,
    files: ActionFileSystem = inertActionFileSystem()
) async throws -> [OCIExecution] {
    try await recordOCIActionExecution(action, files: files).ociExecutions
}

func nonEmptyDirectoryActionFileSystem() -> ActionFileSystem {
    let directory = ActionFileSystem.Metadata(
        type: .directory,
        ownerExecutable: true)
    return ActionFileSystem(
        metadata: { _ in directory },
        metadataNoFollow: { _ in nil },
        contentsEqual: { _, _ in true },
        createDirectory: { _ in },
        copy: { _, _ in },
        read: { _ in [] },
        remove: { _ in },
        move: { _, _ in },
        listRecursively: { root in
            [
                ActionFileSystem.Entry(
                    path: root.appending("generated"),
                    relativePath: "generated",
                    metadata: ActionFileSystem.Metadata(
                        type: .regular,
                        ownerExecutable: false))
            ]
        },
        setPermissions: { _, _ in },
        write: { _, _ in })
}
