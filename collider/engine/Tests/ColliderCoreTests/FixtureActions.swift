import ColliderCore
import SystemPackage

struct FixtureWriteAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let path: FilePath
        let bytes: [UInt8]

        func encodeIdentity(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: path.string)
            encoder.append(tag: 2, bytes: bytes)
        }
    }

    static let kind = ActionKind(rawValue: "fixture.write-file")

    let identity: Identity
    let requirements: ActionRequirements

    init(path: FilePath, bytes: [UInt8]) {
        identity = Identity(path: path, bytes: bytes)
        requirements = ActionRequirements(effects: [
            ActionEffect(.write, scope: .output(path))
        ])
    }

    func execute(in context: ActionContext) async throws {
        try context.files.write(identity.bytes, to: identity.path)
    }
}

func fixtureWriteOperation(
    _ path: FilePath,
    bytes: [UInt8]
) throws -> TaskOperation {
    .action(try AnyColliderAction(FixtureWriteAction(path: path, bytes: bytes)))
}

struct FixtureCreateDirectoryAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let path: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: path.string)
        }
    }

    static let kind = ActionKind(rawValue: "fixture.create-directory")

    let path: FilePath

    var identity: Identity { Identity(path: path) }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.write, scope: .output(path))
        ])
    }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(path)
    }
}

func fixtureCreateDirectoryOperation(_ path: FilePath) throws -> TaskOperation {
    .action(try AnyColliderAction(FixtureCreateDirectoryAction(path: path)))
}

struct FixturePrepareDirectoryAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let path: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: path.string)
        }
    }

    static let kind = ActionKind(rawValue: "fixture.prepare-directory")

    let path: FilePath

    var identity: Identity { Identity(path: path) }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.readWrite, scope: .output(path))
        ])
    }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(path)
        try context.files.createDirectory(path)
    }
}

func fixturePrepareDirectoryOperation(_ path: FilePath) throws -> TaskOperation {
    .action(try AnyColliderAction(FixturePrepareDirectoryAction(path: path)))
}

struct FixtureReplaceSymlinkAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let path: FilePath
        let target: String

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: path.string)
            encoder.append(tag: 2, string: target)
        }
    }

    static let kind = ActionKind(rawValue: "fixture.replace-symlink")

    let path: FilePath
    let target: String

    var identity: Identity { Identity(path: path, target: target) }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.write, scope: .output(path))
        ])
    }

    func execute(in context: ActionContext) async throws {
        try context.files.replaceSymlink(at: path, target: target)
    }
}

func fixtureReplaceSymlinkOperation(
    path: FilePath,
    target: String
) throws -> TaskOperation {
    .action(
        try AnyColliderAction(
            FixtureReplaceSymlinkAction(path: path, target: target)))
}

struct FixturePruneDirectoriesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let plan: DirectoryRetentionPlan

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: plan.safetyRoot.string)
            encoder.append(
                tag: 2,
                string: plan.rules.map {
                    [
                        $0.root.string,
                        $0.current?.string ?? "",
                        String($0.retain),
                        $0.naming.rawValue,
                    ].joined(separator: "\u{0}")
                }.joined(separator: "\u{1}"))
        }
    }

    static let kind = ActionKind(rawValue: "fixture.prune-directories")

    let plan: DirectoryRetentionPlan

    var identity: Identity { Identity(plan: plan) }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: plan.rules.map {
                ActionEffect(.readWrite, scope: .scratch($0.root))
            })
    }

    func execute(in context: ActionContext) async throws {
        try context.files.pruneDirectories(plan)
    }
}

func fixturePruneDirectoriesOperation(
    _ plan: DirectoryRetentionPlan
) throws -> TaskOperation {
    .action(try AnyColliderAction(FixturePruneDirectoriesAction(plan: plan)))
}
