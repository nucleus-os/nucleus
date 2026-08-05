import ColliderCore
import SystemPackage

struct FixtureCommandAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let command: CommandSpec

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: String(describing: command.executable))
            encoder.append(tag: 2, string: command.workingDirectory.string)
            var arguments = CanonicalDigestEncoder()
            for argument in command.arguments {
                arguments.append(tag: 1, string: argument)
            }
            encoder.append(tag: 3, bytes: arguments.bytes)
            var environment = CanonicalDigestEncoder()
            let volatile = Set(["PATH", "NUCLEUS_RUN_DIR", "NUCLEUS_RUN_LOG", "TERM"])
            for (name, value) in command.environment.filter({
                !volatile.contains($0.key)
            }).sorted(by: { $0.key < $1.key }) {
                environment.append(tag: 1, string: name)
                environment.append(tag: 2, string: value)
            }
            encoder.append(tag: 4, bytes: environment.bytes)
        }
    }

    static let kind = ActionKind(rawValue: "fixture.command")

    let identity: Identity
    let requirements: ActionRequirements
    var environment: [String: String] { identity.command.environment }

    init(command: CommandSpec) {
        identity = Identity(command: command)
        let tool: ActionToolRequirement? =
            switch command.executable {
            case .named(let name):
                ActionToolRequirement(name, executable: command.executable, role: .semantic)
            case .path:
                ActionToolRequirement("command", executable: command.executable, role: .semantic)
            case .operationalNamed(let name):
                ActionToolRequirement(name, executable: command.executable, role: .operational)
            case .taskOutput:
                nil
            }
        requirements = ActionRequirements(
            tools: tool.map { [$0] } ?? [],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(identity.command)
        guard result.status == 0 else {
            throw FixtureActionFailure.commandFailed(result.status)
        }
    }
}

func fixtureCommandAction(_ command: CommandSpec) throws -> AnyColliderAction {
    try AnyColliderAction(FixtureCommandAction(command: command))
}

struct FixtureOCIExecutionAction: ColliderAction {
    static let kind = ActionKind(rawValue: "fixture.oci-execution")

    let identity: OCIExecutionActionIdentity
    var requirements: ActionRequirements {
        ociActionRequirements(execution: identity.execution)
    }
    var environment: [String: String] { identity.execution.environment }

    func execute(in context: ActionContext) async throws {
        let result = try await context.containers.run(identity.execution)
        guard result.status == 0 else {
            throw FixtureActionFailure.commandFailed(result.status)
        }
    }
}

func fixtureOCIExecutionAction(_ execution: OCIExecution) throws -> AnyColliderAction {
    try AnyColliderAction(
        FixtureOCIExecutionAction(identity: OCIExecutionActionIdentity(execution)))
}

struct FixtureWriteAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let path: FilePath
        let bytes: [UInt8]

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: path.string)
            encoder.append(tag: 2, bytes: bytes)
        }
    }

    static let kind = ActionKind(rawValue: "fixture.write-file")

    let identity: Identity
    let requirements: ActionRequirements

    init(path: FilePath, bytes: [UInt8]) {
        identity = Identity(path: path, bytes: bytes)
        requirements = ActionRequirements(
            effects: [
                ActionEffect(.write, scope: .output(path))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.write(identity.bytes, to: identity.path)
    }
}

func fixtureWriteAction(
    _ path: FilePath,
    bytes: [UInt8]
) throws -> AnyColliderAction {
    try AnyColliderAction(FixtureWriteAction(path: path, bytes: bytes))
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
        ActionRequirements(
            effects: [
                ActionEffect(.write, scope: .output(path))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.createDirectory(path)
    }
}

func fixtureCreateDirectoryAction(_ path: FilePath) throws -> AnyColliderAction {
    try AnyColliderAction(FixtureCreateDirectoryAction(path: path))
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
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .output(path))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(path)
        try context.files.createDirectory(path)
    }
}

func fixturePrepareDirectoryAction(_ path: FilePath) throws -> AnyColliderAction {
    try AnyColliderAction(FixturePrepareDirectoryAction(path: path))
}

struct FixturePrepareAndWriteAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let root: FilePath
        let file: FilePath
        let bytes: [UInt8]
        let reset: Bool

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: root.string)
            encoder.append(tag: 2, string: file.string)
            encoder.append(tag: 3, bytes: bytes)
            encoder.append(tag: 4, integer: reset ? 1 : 0)
        }
    }

    static let kind = ActionKind(rawValue: "fixture.prepare-and-write")

    let identity: Identity
    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .output(identity.root))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        if identity.reset {
            try context.files.remove(identity.root)
        }
        try context.files.createDirectory(identity.root)
        try context.files.write(identity.bytes, to: identity.file)
    }
}

func fixturePrepareAndWriteAction(
    root: FilePath,
    file: FilePath,
    bytes: [UInt8],
    reset: Bool
) throws -> AnyColliderAction {
    try AnyColliderAction(
        FixturePrepareAndWriteAction(
            identity: FixturePrepareAndWriteAction.Identity(
                root: root,
                file: file,
                bytes: bytes,
                reset: reset)))
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
        ActionRequirements(
            effects: [
                ActionEffect(.write, scope: .output(path))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.replaceSymlink(at: path, target: target)
    }
}

func fixtureReplaceSymlinkAction(
    path: FilePath,
    target: String
) throws -> AnyColliderAction {

    try AnyColliderAction(
        FixtureReplaceSymlinkAction(path: path, target: target))
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
            }
                + plan.rules.compactMap { rule in
                    rule.current.map {
                        ActionEffect(.read, scope: .input($0))
                    }
                },
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.pruneDirectories(plan)
    }
}

func fixturePruneDirectoriesAction(
    _ plan: DirectoryRetentionPlan
) throws -> AnyColliderAction {
    try AnyColliderAction(FixturePruneDirectoriesAction(plan: plan))
}

struct FixtureActivateGenerationAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let candidate: FilePath
        let generation: FilePath
        let active: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: candidate.string)
            encoder.append(tag: 2, string: generation.string)
            encoder.append(tag: 3, string: active.string)
        }
    }

    static let kind = ActionKind(rawValue: "fixture.activate-generation")

    let candidate: FilePath
    let generation: FilePath
    let active: FilePath

    var identity: Identity {
        Identity(candidate: candidate, generation: generation, active: active)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .output(candidate)),
                ActionEffect(.write, scope: .output(generation)),
                ActionEffect(.write, scope: .publication(active)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        guard
            try context.files.metadata(for: candidate)?.type == .directory,
            !(try context.files.listRecursively(candidate)).isEmpty
        else {
            throw FixtureActionFailure.invalidGenerationCandidate(candidate)
        }
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generation,
            active: active)
    }
}

func fixtureActivateGenerationAction(
    candidate: FilePath,
    generation: FilePath,
    active: FilePath
) throws -> AnyColliderAction {

    try AnyColliderAction(
        FixtureActivateGenerationAction(
            candidate: candidate,
            generation: generation,
            active: active))
}

enum FixtureActionFailure: Error {
    case invalidGenerationCandidate(FilePath)
    case commandFailed(Int32)
}

struct FixturePrepareOCIImageAction: ColliderAction {
    static let kind = ActionKind(rawValue: "fixture.prepare-oci-image")

    let identity: OCIImagePreparationActionIdentity

    init(preparation: OCIImagePreparation) {
        identity = OCIImagePreparationActionIdentity(preparation)
    }

    var requirements: ActionRequirements {
        ociImagePreparationActionRequirements(preparation: identity.preparation)
    }

    var environment: [String: String] { identity.preparation.environment }

    func execute(in context: ActionContext) async throws {
        try await context.containers.prepareImage(identity.preparation)
    }
}

func fixturePrepareOCIImageAction(
    _ preparation: OCIImagePreparation
) throws -> AnyColliderAction {

    try AnyColliderAction(
        FixturePrepareOCIImageAction(preparation: preparation))
}
