import ColliderCore
import SystemPackage

struct FixtureCommandAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let command: CommandSpec

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(String(describing: command.executable))
            encoder.append(path: command.workingDirectory)
            encoder.appendSequence(command.arguments) { $0.append($1) }
            let volatile = Set(["PATH", "TERM"])
            encoder.appendSequence(
                command.environment.filter({
                    !volatile.contains($0.key)
                }).sorted(by: { $0.key < $1.key })
            ) {
                environment, entry in
                environment.append(entry.key)
                environment.append(entry.value)
            }
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
            case .path, .artifact:
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
        let result = try await context.containers.execute(identity.execution)
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: path)
            encoder.append(bytes: bytes)
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: path)
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: path)
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: root)
            encoder.append(path: file)
            encoder.append(bytes: bytes)
            encoder.append(reset)
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: path)
            encoder.append(target)
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: plan.safetyRoot)
            encoder.appendSequence(plan.rules) { ruleEncoder, rule in
                ruleEncoder.append(path: rule.root)
                ruleEncoder.appendOptional(rule.current) { $0.append(path: $1) }
                ruleEncoder.append(UInt64(rule.retain))
                ruleEncoder.appendEnum(rule.naming)
            }
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

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: candidate)
            encoder.append(path: generation)
            encoder.append(path: active)
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
    var imagePreparations: [OCIImagePreparation] { [identity.preparation] }

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
