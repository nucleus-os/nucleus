import SystemPackage

public struct ActionKind: RawRepresentable, Hashable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }
}

public protocol ColliderActionIdentity: Hashable, Sendable {
    func encode(into encoder: inout IdentityEncoder)
}

public struct DownloadActionIdentity: ColliderActionIdentity {
    public let specification: DownloadSpec
    public let destination: FilePath

    public init(specification: DownloadSpec, destination: FilePath) {
        self.specification = specification
        self.destination = destination
    }

    public func encode(into encoder: inout IdentityEncoder) {
        encoder.append(specification.url.absoluteString)
        encoder.append(bytes: specification.expectedDigest.bytes)
        encoder.append(path: destination)
        encoder.appendSequence(specification.permittedRedirectOrigins.sorted()) {
            $0.append($1)
        }
        encoder.append(UInt64(specification.maximumResponseSize))

        encoder.appendSequence(
            specification.acceptedMediaTypes.map { $0.lowercased() }.sorted()
        ) { $0.append($1) }
        encoder.append(specification.requestTimeoutSeconds)
        encoder.append(specification.inactivityTimeoutSeconds)
        encoder.append(UInt64(specification.maximumRedirects))
        encoder.append(UInt64(specification.maximumRetries))
        encoder.append(specification.resumption.rawValue)
    }

    public func validateOutput(using files: ActionFileSystem) throws {
        let actual = try files.digest(file: destination)
        guard actual == specification.expectedDigest else {
            throw DownloadActionValidationFailure.digestMismatch(
                path: destination,
                expected: specification.expectedDigest,
                actual: actual)
        }
    }
}

public enum DownloadActionValidationFailure: Error, CustomStringConvertible, Sendable {
    case digestMismatch(
        path: FilePath,
        expected: ArtifactDigest,
        actual: ArtifactDigest)

    public var description: String {
        switch self {
        case .digestMismatch(let path, let expected, let actual):
            "download digest mismatch for \(path): expected \(expected), got \(actual)"
        }
    }
}

public enum ActionToolRole: String, Hashable, Sendable {
    case semantic
    case operational
}

public struct ActionToolRequirement: Hashable, Sendable {
    public let name: String
    public let executable: CommandSpec.Executable
    public let role: ActionToolRole

    public init(
        _ name: String,
        executable: CommandSpec.Executable,
        role: ActionToolRole
    ) {
        self.name = name
        self.executable = executable
        self.role = role
    }
}

public enum ActionEffectAccess: String, Hashable, Sendable {
    case read
    case write
    case readWrite
}

public enum ActionEffectScope: Hashable, Sendable {
    case input(FilePath)
    case checkout(FilePath)
    case scratch(FilePath)
    case output(FilePath)
    case publication(FilePath)
    case unrestricted(FilePath)

    public var root: FilePath {
        switch self {
        case .input(let root), .checkout(let root), .scratch(let root), .output(let root),
            .publication(let root), .unrestricted(let root):
            root
        }
    }
}

public struct ActionCancellation: Sendable {
    private let checkBody: @Sendable () throws -> Void

    public init(check: @escaping @Sendable () throws -> Void) {
        checkBody = check
    }

    public func check() throws {
        try checkBody()
    }
}

public struct ActionLogger: Sendable {
    private let logBody: @Sendable (String) async throws -> Void

    public init(log: @escaping @Sendable (String) async throws -> Void) {
        logBody = log
    }

    public func log(_ message: String) async throws {
        try await logBody(message)
    }
}

public struct ActionCommandExecutor: Sendable {
    private let executeBody: @Sendable (CommandSpec) async throws -> CommandResult

    public init(
        execute: @escaping @Sendable (CommandSpec) async throws -> CommandResult
    ) {
        executeBody = execute
    }

    public func execute(_ command: CommandSpec) async throws -> CommandResult {
        try await executeBody(command)
    }
}

public struct ActionDownloader: Sendable {
    private let downloadBody: @Sendable (DownloadSpec, FilePath) async throws -> Void

    public init(
        download: @escaping @Sendable (DownloadSpec, FilePath) async throws -> Void
    ) {
        downloadBody = download
    }

    public func download(_ specification: DownloadSpec, to path: FilePath) async throws {
        try await downloadBody(specification, path)
    }
}

public struct ActionContainerExecutor: Sendable {
    private let prepareImageBody: @Sendable (OCIImagePreparation) async throws -> Void
    private let runBody: @Sendable (OCIExecution) async throws -> CommandResult

    public init(
        prepareImage: @escaping @Sendable (OCIImagePreparation) async throws -> Void = {
            _ in throw ActionContainerExecutorFailure.unavailable
        },
        run: @escaping @Sendable (OCIExecution) async throws -> CommandResult = {
            _ in throw ActionContainerExecutorFailure.unavailable
        }
    ) {
        prepareImageBody = prepareImage
        runBody = run
    }

    public func prepareImage(_ preparation: OCIImagePreparation) async throws {
        try await prepareImageBody(preparation)
    }

    public func run(_ execution: OCIExecution) async throws {
        let result = try await execute(execution)
        try result.requireSuccess(reason: "container command failed")
    }

    public func execute(_ execution: OCIExecution) async throws -> CommandResult {
        try await runBody(execution)
    }
}

public struct ActionObservationRecorder: Sendable {
    private let recordBody: @Sendable (ActionStageObservation) -> Void

    public init(
        record: @escaping @Sendable (ActionStageObservation) -> Void = { _ in }
    ) {
        recordBody = record
    }

    public func record(_ observation: ActionStageObservation) {
        recordBody(observation)
    }
}

public enum ActionContainerExecutorFailure: Error, CustomStringConvertible, Sendable {
    case unavailable

    public var description: String {
        switch self {
        case .unavailable:
            "container execution is unavailable"
        }
    }
}

public struct OCIImagePreparationActionIdentity: ColliderActionIdentity {
    public let preparation: OCIImagePreparation

    public init(_ preparation: OCIImagePreparation) {
        self.preparation = preparation
    }

    public func encode(into encoder: inout IdentityEncoder) {
        encoder.append(preparation.executionPlatform.environment.rawValue)
        encoder.append(preparation.executionPlatform.operatingSystem.rawValue)
        encoder.append(preparation.executionPlatform.architecture.rawValue)
        encoder.append(path: preparation.context)
        encoder.append(path: preparation.containerFile)
        encoder.append(path: preparation.imageID)
        encoder.append(preparation.imageName)
        encoder.append(preparation.baseImageSource.rawValue)
        encoder.appendOptional(preparation.localBaseImageID) { $0.append(path: $1) }
        encoder.append(UInt64(preparation.rollbackGenerationCount))
    }
}

public struct OCIMountedEntrypointActionIdentity: ColliderActionIdentity {
    public let entrypoint: OCIMountedEntrypoint

    public init(_ entrypoint: OCIMountedEntrypoint) {
        self.entrypoint = entrypoint
    }

    public func encode(into encoder: inout IdentityEncoder) {
        encoder.append(path: entrypoint.image.path)
        encoder.append(path: entrypoint.executable)
        encoder.append(entrypoint.containerPath)
    }
}

public struct OCIExecutionActionIdentity: ColliderActionIdentity {
    public let execution: OCIExecution

    public init(_ execution: OCIExecution) {
        self.execution = execution
    }

    public func encode(into encoder: inout IdentityEncoder) {
        encoder.append(execution.executionPlatform.environment.rawValue)
        encoder.append(execution.executionPlatform.operatingSystem.rawValue)
        encoder.append(execution.executionPlatform.architecture.rawValue)
        encoder.append(execution.artifactTarget.operatingSystem.rawValue)
        encoder.append(execution.artifactTarget.architecture.rawValue)
        encoder.append(execution.artifactTarget.abi ?? "")
        encoder.append(UInt64(execution.artifactTarget.androidAPILevel ?? 0))
        encoder.append(path: execution.imageID)
        encoder.append(execution.hostname)
        encoder.append(execution.workingDirectory)
        encoder.append(path: execution.hostWorkingDirectory)

        encoder.appendSequence(execution.mounts) { mountEncoder, mount in
            mountEncoder.append(path: mount.source)
            mountEncoder.append(mount.target)
            mountEncoder.appendEnum(mount.purpose)
        }
        encoder.appendSequence(execution.persistentWorkspaceMounts) { workspace, mount in
            workspace.append(mount.workspace.identity.key)
            workspace.appendEnum(mount.workspace.identity.artifactTarget.operatingSystem)
            workspace.appendEnum(mount.workspace.identity.artifactTarget.architecture)
            workspace.appendOptional(mount.workspace.identity.artifactTarget.abi) {
                $0.append($1)
            }
            workspace.appendOptional(mount.workspace.identity.artifactTarget.androidAPILevel) {
                $0.append(UInt64($1))
            }
            workspace.append(mount.workspace.identity.role)
            workspace.append(mount.target)
            workspace.appendEnum(mount.access)
        }
        encoder.append(UInt64(execution.userPolicy.userID))
        encoder.append(UInt64(execution.userPolicy.groupID))
        encoder.append(execution.capabilityPolicy.rawValue)
        encoder.append(execution.privilegePolicy.rawValue)
        encoder.append(execution.processFilesystemPolicy.rawValue)
        encoder.appendSequence(
            execution.executableRequirements.sorted {
                if $0.architecture != $1.architecture {
                    return $0.architecture.rawValue < $1.architecture.rawValue
                }
                return $0.executable < $1.executable
            }
        ) { requirement, value in
            requirement.appendEnum(value.architecture)
            requirement.append(value.executable)
        }

        // Resource limits schedule an execution but cannot change its declared
        // result. Tuning them must not invalidate otherwise clean artifacts.

        encoder.appendSequence(execution.containerEnvironment.sorted { $0.key < $1.key }) {
            entry, value in
            entry.append(value.key)
            entry.append(argument: value.value)
        }
        encoder.appendOptional(execution.imageEntrypointOverride) {
            $0.append($1)
        }
        encoder.appendSequence(execution.command) { $0.append($1) }
        encoder.append(ociActionOutputIdentity(execution.output))
    }
}

public struct OCIExecutionPipelineIdentity: ColliderActionIdentity {
    public let executions: [OCIExecution]

    public init(_ executions: [OCIExecution]) {
        self.executions = executions
    }

    public func encode(into encoder: inout IdentityEncoder) {
        encoder.appendSequence(executions) { executionEncoder, execution in
            OCIExecutionActionIdentity(execution).encode(into: &executionEncoder)
        }
    }
}

public enum OCIExecutionPipelineFailure: Error, CustomStringConvertible, Sendable {
    case empty
    case mixedExecutionPlatforms
    case mixedArtifactTargets
    case mixedEnvironments

    public var description: String {
        switch self {
        case .empty:
            "an OCI execution pipeline must contain at least one execution"
        case .mixedExecutionPlatforms:
            "all OCI executions in one action must use the same execution platform"
        case .mixedArtifactTargets:
            "all OCI executions in one action must produce the same artifact target"
        case .mixedEnvironments:
            "all OCI executions in one action must use the same host environment"
        }
    }
}

public struct OCIExecutionPipeline: Sendable {
    public let executions: [OCIExecution]
    public let identity: OCIExecutionPipelineIdentity
    public let requirements: ActionRequirements
    public let environment: [String: String]

    public init(_ executions: [OCIExecution]) throws {
        guard let first = executions.first else {
            throw OCIExecutionPipelineFailure.empty
        }
        guard
            executions.allSatisfy({
                $0.executionPlatform == first.executionPlatform
            })
        else {
            throw OCIExecutionPipelineFailure.mixedExecutionPlatforms
        }
        guard
            executions.allSatisfy({
                $0.artifactTarget == first.artifactTarget
            })
        else {
            throw OCIExecutionPipelineFailure.mixedArtifactTargets
        }
        guard executions.allSatisfy({ $0.environment == first.environment }) else {
            throw OCIExecutionPipelineFailure.mixedEnvironments
        }

        var effects: [ActionEffect] = []
        var persistentWorkspaceEffects: [ActionPersistentWorkspaceEffect] = []
        for execution in executions {
            let executionRequirements = ociActionRequirements(execution: execution)
            for effect in executionRequirements.effects
            where !effects.contains(effect) {
                effects.append(effect)
            }
            for effect in executionRequirements.persistentWorkspaceEffects
            where !persistentWorkspaceEffects.contains(effect) {
                persistentWorkspaceEffects.append(effect)
            }
        }

        self.executions = executions
        identity = OCIExecutionPipelineIdentity(executions)
        requirements = ActionRequirements(
            effects: effects,
            persistentWorkspaceEffects: persistentWorkspaceEffects,
            lane: .oci,
            networkAccess: .none,
            executionPlatform: first.executionPlatform,
            artifactTarget: first.artifactTarget)
        environment = first.environment
    }

    public func execute(in context: ActionContext) async throws {
        for (index, execution) in executions.enumerated() {
            try context.cancellation.check()
            let result = try await context.containers.execute(execution)
            try result.requireSuccess(
                reason: "OCI pipeline command \(index) failed")
        }
    }
}

public func ociActionRequirements(
    execution: OCIExecution
) -> ActionRequirements {
    var effects = [
        ActionEffect(.read, scope: .input(execution.imageID))
    ]
    for mount in execution.mounts {
        let effect = ActionEffect(
            mount.isReadOnly ? .read : .readWrite,
            scope: mount.isReadOnly
                ? .input(mount.source) : .output(mount.source))
        if !effects.contains(effect) { effects.append(effect) }
    }
    let persistentWorkspaceEffects = execution.persistentWorkspaceMounts.map {
        ActionPersistentWorkspaceEffect(
            workspace: $0.workspace,
            target: $0.target,
            access: $0.access)
    }
    return ActionRequirements(
        effects: effects,
        persistentWorkspaceEffects: persistentWorkspaceEffects,
        lane: .oci,
        networkAccess: .none,
        executionPlatform: execution.executionPlatform,
        artifactTarget: execution.artifactTarget)
}

public func ociImagePreparationActionRequirements(
    preparation: OCIImagePreparation
) -> ActionRequirements {
    ActionRequirements(
        effects: [
            ActionEffect(.read, scope: .input(preparation.context)),
            ActionEffect(.readWrite, scope: .output(preparation.imageID)),
        ],
        lane: .hostExclusive,
        networkAccess: .contentAddressed,
        executionPlatform: preparation.executionPlatform)
}

private func ociActionOutputIdentity(_ output: CommandSpec.Output) -> String {
    switch output {
    case .inherited:
        "inherited"
    case .logged:
        "logged"
    case .terminal:
        "terminal"
    case .file(let path):
        "file:\(path)"
    case .captured(let limit):
        "captured:\(limit)"
    case .combined(let limit):
        "combined:\(limit)"
    }
}

public struct ActionEffect: Hashable, Sendable {
    public let access: ActionEffectAccess
    public let scope: ActionEffectScope

    public init(_ access: ActionEffectAccess, scope: ActionEffectScope) {
        self.access = access
        self.scope = scope
    }
}

public struct ActionPersistentWorkspaceEffect: Hashable, Sendable {
    public let workspace: PersistentWorkspaceDeclaration
    public let target: String
    public let access: OCIPersistentWorkspaceMount.Access

    public init(
        workspace: PersistentWorkspaceDeclaration,
        target: String,
        access: OCIPersistentWorkspaceMount.Access
    ) {
        self.workspace = workspace
        self.target = target
        self.access = access
    }
}

public struct ActionRequirements: Hashable, Sendable {
    public let tools: [ActionToolRequirement]
    public let effects: [ActionEffect]
    public let persistentWorkspaceEffects: [ActionPersistentWorkspaceEffect]
    public let lane: TaskExecutionLane
    public let networkAccess: ActionNetworkAccess
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget?

    public init(
        tools: [ActionToolRequirement] = [],
        effects: [ActionEffect] = [],
        persistentWorkspaceEffects: [ActionPersistentWorkspaceEffect] = [],
        lane: TaskExecutionLane? = nil,
        networkAccess: ActionNetworkAccess = .none,
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget? = nil
    ) {
        self.tools = tools
        self.effects = effects
        self.persistentWorkspaceEffects = persistentWorkspaceEffects
        self.lane =
            lane
            ?? (executionPlatform.environment == .oci ? .oci : .lightweight)
        self.networkAccess = networkAccess
        self.executionPlatform = executionPlatform
        self.artifactTarget = artifactTarget
    }
}

public enum ActionNetworkAccess: String, Hashable, Sendable {
    case none
    /// External access is permitted only to materialize bytes verified against
    /// an exact content digest declared by the action.
    case contentAddressed
    case unrestricted
}

public enum ActionDeclarationFailure: Error, CustomStringConvertible, Sendable {
    case emptyKind
    case duplicateToolName(String)
    case conflictingToolRole(CommandSpec.Executable)
    case duplicateEffect(ActionEffect)
    case relativeEffectRoot(FilePath)
    case noncanonicalEffectRoot(FilePath)
    case invalidPersistentWorkspaceKey(String)
    case invalidPersistentWorkspaceRole(String)
    case invalidPersistentWorkspaceCapacity(PersistentWorkspaceIdentity)
    case invalidPersistentWorkspaceJournal(PersistentWorkspaceIdentity)
    case invalidPersistentWorkspaceRetention(PersistentWorkspaceIdentity)
    case duplicatePersistentWorkspace(PersistentWorkspaceIdentity)
    case conflictingPersistentWorkspaceDeclaration(PersistentWorkspaceIdentity)
    case persistentWorkspaceTargetMismatch(
        workspace: PersistentWorkspaceIdentity,
        artifactTarget: ArtifactTarget?)
    case invalidPersistentWorkspaceMountTarget(String)
    case overlappingPersistentWorkspaceMountTargets(String, String)

    public var description: String {
        switch self {
        case .emptyKind:
            "action kind must not be empty"
        case .duplicateToolName(let name):
            "action tool requirement name '\(name)' is duplicated"
        case .conflictingToolRole(let executable):
            "action tool '\(executable)' has both semantic and operational roles"
        case .duplicateEffect(let effect):
            "action effect '\(effect)' is duplicated"
        case .relativeEffectRoot(let root):
            "action effect root must be absolute: \(root)"
        case .noncanonicalEffectRoot(let root):
            "action effect root must be lexically normalized: \(root)"
        case .invalidPersistentWorkspaceKey(let key):
            "persistent workspace key is invalid: \(key)"
        case .invalidPersistentWorkspaceRole(let role):
            "persistent workspace role is invalid: \(role)"
        case .invalidPersistentWorkspaceCapacity(let identity):
            "persistent workspace capacity must be positive: \(identity.key)"
        case .invalidPersistentWorkspaceJournal(let identity):
            "persistent workspace journal must be nonempty and smaller than its capacity: \(identity.key)"
        case .invalidPersistentWorkspaceRetention(let identity):
            "persistent workspace retention must be protected, explicit-clean, or a positive tool limit no larger than its capacity: \(identity.key)"
        case .duplicatePersistentWorkspace(let identity):
            "persistent workspace is mounted more than once by one action: \(identity.key)"
        case .conflictingPersistentWorkspaceDeclaration(let identity):
            "persistent workspace has conflicting declarations: \(identity.key)"
        case .persistentWorkspaceTargetMismatch(let workspace, let artifactTarget):
            "persistent workspace target does not match action artifact target: \(workspace.key) (\(String(describing: artifactTarget)))"
        case .invalidPersistentWorkspaceMountTarget(let target):
            "persistent workspace mount target must be an absolute normalized guest path: \(target)"
        case .overlappingPersistentWorkspaceMountTargets(let first, let second):
            "persistent workspace mount targets overlap: \(first) and \(second)"
        }
    }
}

public protocol ColliderAction: Sendable {
    associatedtype Identity: ColliderActionIdentity

    static var kind: ActionKind { get }

    var identity: Identity { get }
    var requirements: ActionRequirements { get }
    var environment: [String: String] { get }
    var imagePreparations: [OCIImagePreparation] { get }

    func execute(in context: ActionContext) async throws
    func validateOutputs(using files: ActionFileSystem) throws
}

extension ColliderAction {
    public var environment: [String: String] { [:] }
    public var imagePreparations: [OCIImagePreparation] { [] }
    public func validateOutputs(using _: ActionFileSystem) throws {}
}

public struct AnyColliderAction: Hashable, Sendable {
    public let kind: ActionKind
    public let implementationType: String
    public let identity: [UInt8]
    public let requirements: ActionRequirements
    public let environment: [String: String]
    public let imagePreparations: [OCIImagePreparation]

    private let body: @Sendable (ActionContext) async throws -> Void
    private let validationBody: @Sendable (ActionFileSystem) throws -> Void
    private let identityBody: @Sendable (IdentityPathMap) -> [UInt8]

    public init<Action: ColliderAction>(_ action: Action) throws {
        try Self.validate(kind: Action.kind, requirements: action.requirements)
        var encoder = IdentityEncoder()
        action.identity.encode(into: &encoder)
        kind = Action.kind
        implementationType = String(reflecting: Action.self)
        identity = encoder.bytes
        identityBody = { pathMap in
            var encoder = IdentityEncoder(identityPathMap: pathMap)
            action.identity.encode(into: &encoder)
            return encoder.bytes
        }
        requirements = action.requirements
        environment = action.environment
        imagePreparations = action.imagePreparations
        body = { context in
            try await action.execute(in: context)
        }
        validationBody = { files in
            try action.validateOutputs(using: files)
        }
    }

    private static func validate(
        kind: ActionKind,
        requirements: ActionRequirements
    ) throws {
        guard !kind.rawValue.isEmpty else {
            throw ActionDeclarationFailure.emptyKind
        }
        var names: Set<String> = []
        var roles: [CommandSpec.Executable: ActionToolRole] = [:]
        for tool in requirements.tools {
            guard names.insert(tool.name).inserted else {
                throw ActionDeclarationFailure.duplicateToolName(tool.name)
            }
            if let role = roles[tool.executable], role != tool.role {
                throw ActionDeclarationFailure.conflictingToolRole(tool.executable)
            }
            roles[tool.executable] = tool.role
        }
        var effects: Set<ActionEffect> = []
        for effect in requirements.effects {
            guard effects.insert(effect).inserted else {
                throw ActionDeclarationFailure.duplicateEffect(effect)
            }
            guard effect.scope.root.string.hasPrefix("/") else {
                throw ActionDeclarationFailure.relativeEffectRoot(effect.scope.root)
            }
            guard effect.scope.root.lexicallyNormalized() == effect.scope.root else {
                throw ActionDeclarationFailure.noncanonicalEffectRoot(effect.scope.root)
            }
        }
        var workspaces: [PersistentWorkspaceIdentity: PersistentWorkspaceDeclaration] = [:]
        var mountTargets: [FilePath] = []
        for effect in requirements.persistentWorkspaceEffects {
            let identity = effect.workspace.identity
            guard isValidPersistentWorkspaceField(identity.key) else {
                throw ActionDeclarationFailure.invalidPersistentWorkspaceKey(identity.key)
            }
            guard isValidPersistentWorkspaceField(identity.role) else {
                throw ActionDeclarationFailure.invalidPersistentWorkspaceRole(identity.role)
            }
            guard effect.workspace.capacityBytes > 0 else {
                throw ActionDeclarationFailure.invalidPersistentWorkspaceCapacity(identity)
            }
            guard effect.workspace.journal.sizeBytes > 0,
                effect.workspace.journal.sizeBytes < effect.workspace.capacityBytes
            else {
                throw ActionDeclarationFailure.invalidPersistentWorkspaceJournal(identity)
            }
            switch effect.workspace.retentionPolicy {
            case .protected, .explicitClean:
                break
            case .toolManagedLimit(let maximumBytes):
                guard maximumBytes > 0,
                    maximumBytes <= effect.workspace.capacityBytes
                else {
                    throw ActionDeclarationFailure.invalidPersistentWorkspaceRetention(identity)
                }
            default:
                throw ActionDeclarationFailure.invalidPersistentWorkspaceRetention(identity)
            }
            guard identity.artifactTarget == requirements.artifactTarget else {
                throw ActionDeclarationFailure.persistentWorkspaceTargetMismatch(
                    workspace: identity,
                    artifactTarget: requirements.artifactTarget)
            }
            if let declared = workspaces[identity] {
                guard declared == effect.workspace else {
                    throw ActionDeclarationFailure.conflictingPersistentWorkspaceDeclaration(
                        identity)
                }
                throw ActionDeclarationFailure.duplicatePersistentWorkspace(identity)
            }
            workspaces[identity] = effect.workspace

            let target = FilePath(effect.target).lexicallyNormalized()
            guard effect.target.hasPrefix("/"), effect.target != "/",
                !effect.target.split(separator: "/").contains(".."),
                target.string == effect.target
            else {
                throw ActionDeclarationFailure.invalidPersistentWorkspaceMountTarget(
                    effect.target)
            }
            if let overlapping = mountTargets.first(where: { $0.overlaps(target) }) {
                throw ActionDeclarationFailure.overlappingPersistentWorkspaceMountTargets(
                    overlapping.string,
                    target.string)
            }
            mountTargets.append(target)
        }
    }

    public func execute(in context: ActionContext) async throws {
        try await body(context)
    }

    public func validateOutputs(using files: ActionFileSystem) throws {
        try validationBody(files)
    }

    public func identity(using pathMap: IdentityPathMap) -> [UInt8] {
        identityBody(pathMap)
    }

    public static func == (
        lhs: AnyColliderAction,
        rhs: AnyColliderAction
    ) -> Bool {
        lhs.kind == rhs.kind
            && lhs.identity == rhs.identity
            && lhs.requirements == rhs.requirements
            && lhs.environment == rhs.environment
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(identity)
        hasher.combine(requirements)
        hasher.combine(environment)
    }
}

private func isValidPersistentWorkspaceField(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128,
        let first = value.utf8.first,
        (first >= 97 && first <= 122) || (first >= 48 && first <= 57)
    else { return false }
    return value.utf8.allSatisfy {
        ($0 >= 97 && $0 <= 122)
            || ($0 >= 48 && $0 <= 57)
            || $0 == 46
            || $0 == 95
            || $0 == 45
    }
}

public struct ActionContext: Sendable {
    public let files: ActionFileSystem
    public let cancellation: ActionCancellation
    public let logger: ActionLogger
    public let commands: ActionCommandExecutor
    public let downloads: ActionDownloader
    public let containers: ActionContainerExecutor
    public let observations: ActionObservationRecorder

    public init(
        files: ActionFileSystem,
        cancellation: ActionCancellation,
        logger: ActionLogger,
        commands: ActionCommandExecutor,
        downloads: ActionDownloader,
        containers: ActionContainerExecutor = ActionContainerExecutor(),
        observations: ActionObservationRecorder = ActionObservationRecorder()
    ) {
        self.files = files
        self.cancellation = cancellation
        self.logger = logger
        self.commands = commands
        self.downloads = downloads
        self.containers = containers
        self.observations = observations
    }
}

public struct ActionFileSystem: Sendable {
    public enum FileType: Hashable, Sendable {
        case regular
        case directory
        case symbolicLink
        case other
    }

    public struct Metadata: Hashable, Sendable {
        public let type: FileType
        public let ownerExecutable: Bool
        public let size: UInt64
        public let permissions: UInt16

        public init(
            type: FileType,
            ownerExecutable: Bool,
            size: UInt64 = 0,
            permissions: UInt16 = 0
        ) {
            self.type = type
            self.ownerExecutable = ownerExecutable
            self.size = size
            self.permissions = permissions
        }
    }

    public struct Entry: Hashable, Sendable {
        public let path: FilePath
        public let relativePath: String
        public let metadata: Metadata

        public init(
            path: FilePath,
            relativePath: String,
            metadata: Metadata
        ) {
            self.path = path
            self.relativePath = relativePath
            self.metadata = metadata
        }
    }

    private let metadataBody: @Sendable (FilePath) throws -> Metadata?
    private let metadataNoFollowBody: @Sendable (FilePath) throws -> Metadata?
    private let contentsEqualBody: @Sendable (FilePath, FilePath) throws -> Bool
    private let createDirectoryBody: @Sendable (FilePath) throws -> Void
    private let copyBody: @Sendable (FilePath, FilePath) throws -> Void
    private let copyTreeBody: @Sendable (FilePath, FilePath) throws -> Void
    private let readBody: @Sendable (FilePath) throws -> [UInt8]
    private let readPrefixBody: @Sendable (FilePath, Int) throws -> [UInt8]
    private let readSymbolicLinkBody: @Sendable (FilePath) throws -> String
    private let removeBody: @Sendable (FilePath) throws -> Void
    private let moveBody: @Sendable (FilePath, FilePath) throws -> Void
    private let listDirectoryBody: @Sendable (FilePath) throws -> [Entry]
    private let normalizeTimestampsBody: @Sendable (FilePath, Int64) throws -> Void
    private let listRecursivelyBody: @Sendable (FilePath) throws -> [Entry]
    private let digestFileBody: @Sendable (FilePath) throws -> ArtifactDigest
    private let digestTreeBody: @Sendable (FilePath, Set<String>) throws -> ArtifactDigest
    private let publishGenerationBody: @Sendable (FilePath, FilePath, FilePath) throws -> Void
    private let pruneDirectoriesBody: @Sendable (DirectoryRetentionPlan) throws -> Void
    private let replaceSymlinkBody: @Sendable (FilePath, String) throws -> Void
    private let setPermissionsBody: @Sendable (FilePath, UInt16) throws -> Void
    private let writeBody: @Sendable ([UInt8], FilePath) throws -> Void

    public init(
        metadata: @escaping @Sendable (FilePath) throws -> Metadata?,
        metadataNoFollow: @escaping @Sendable (FilePath) throws -> Metadata? = {
            _ in throw ActionFileSystemFailure.unavailable("metadataNoFollow")
        },
        contentsEqual:
            @escaping @Sendable (FilePath, FilePath) throws -> Bool,
        createDirectory: @escaping @Sendable (FilePath) throws -> Void,
        copy: @escaping @Sendable (FilePath, FilePath) throws -> Void,
        copyTree: @escaping @Sendable (FilePath, FilePath) throws -> Void = {
            _, _ in throw ActionFileSystemFailure.unavailable("copyTree")
        },
        read: @escaping @Sendable (FilePath) throws -> [UInt8] = {
            _ in throw ActionFileSystemFailure.unavailable("read")
        },
        readPrefix: @escaping @Sendable (FilePath, Int) throws -> [UInt8] = {
            _, _ in throw ActionFileSystemFailure.unavailable("readPrefix")
        },
        readSymbolicLink: @escaping @Sendable (FilePath) throws -> String = {
            _ in throw ActionFileSystemFailure.unavailable("readSymbolicLink")
        },
        remove: @escaping @Sendable (FilePath) throws -> Void = {
            _ in throw ActionFileSystemFailure.unavailable("remove")
        },
        move: @escaping @Sendable (FilePath, FilePath) throws -> Void = {
            _, _ in throw ActionFileSystemFailure.unavailable("move")
        },
        normalizeTimestamps: @escaping @Sendable (FilePath, Int64) throws -> Void = {
            _, _ in throw ActionFileSystemFailure.unavailable("normalizeTimestamps")
        },
        listDirectory: @escaping @Sendable (FilePath) throws -> [Entry] = {
            _ in throw ActionFileSystemFailure.unavailable("listDirectory")
        },
        listRecursively: @escaping @Sendable (FilePath) throws -> [Entry] = {
            _ in throw ActionFileSystemFailure.unavailable("listRecursively")
        },
        digestFile: @escaping @Sendable (FilePath) throws -> ArtifactDigest = {
            _ in throw ActionFileSystemFailure.unavailable("digestFile")
        },
        digestTree:
            @escaping @Sendable (FilePath, Set<String>) throws -> ArtifactDigest = {
                _, _ in throw ActionFileSystemFailure.unavailable("digestTree")
            },
        publishGeneration:
            @escaping @Sendable (FilePath, FilePath, FilePath) throws -> Void = {
                _, _, _ in throw ActionFileSystemFailure.unavailable("publishGeneration")
            },
        pruneDirectories:
            @escaping @Sendable (DirectoryRetentionPlan) throws -> Void = {
                _ in throw ActionFileSystemFailure.unavailable("pruneDirectories")
            },
        replaceSymlink: @escaping @Sendable (FilePath, String) throws -> Void = {
            _, _ in throw ActionFileSystemFailure.unavailable("replaceSymlink")
        },
        setPermissions: @escaping @Sendable (FilePath, UInt16) throws -> Void,
        write: @escaping @Sendable ([UInt8], FilePath) throws -> Void
    ) {
        metadataBody = metadata
        metadataNoFollowBody = metadataNoFollow
        contentsEqualBody = contentsEqual
        createDirectoryBody = createDirectory
        copyBody = copy
        copyTreeBody = copyTree
        readBody = read
        readPrefixBody = readPrefix
        readSymbolicLinkBody = readSymbolicLink
        removeBody = remove
        moveBody = move
        normalizeTimestampsBody = normalizeTimestamps
        listDirectoryBody = listDirectory
        listRecursivelyBody = listRecursively
        digestFileBody = digestFile
        digestTreeBody = digestTree
        publishGenerationBody = publishGeneration
        pruneDirectoriesBody = pruneDirectories
        replaceSymlinkBody = replaceSymlink
        setPermissionsBody = setPermissions
        writeBody = write
    }

    public func metadata(for path: FilePath) throws -> Metadata? {
        try named("metadata", [path]) { try metadataBody(path) }
    }

    public func metadataWithoutFollowingSymlinks(
        for path: FilePath
    ) throws -> Metadata? {
        try metadataNoFollowBody(path)
    }

    public func contentsEqual(
        at first: FilePath,
        and second: FilePath
    ) throws -> Bool {
        try contentsEqualBody(first, second)
    }

    /// Every operation names what it touched when it fails.
    ///
    /// These wrap raw filesystem calls, whose errors are an errno and nothing
    /// else. A build that reads a checkout it may not write, writes a store it
    /// may not own, and stages inputs between them produces the same errno for
    /// three unrelated faults, and a message without a path sends every one of
    /// them to the same wrong diagnosis.
    private func named<Value>(
        _ operation: String,
        _ paths: [FilePath],
        _ body: () throws -> Value
    ) throws -> Value {
        do {
            return try body()
        } catch let failure as ActionFileSystemFailure {
            throw failure
        } catch {
            throw ActionFileSystemFailure.operationFailed(
                operation: operation,
                paths: paths.map(\.string),
                reason: String(describing: error))
        }
    }

    public func createDirectory(_ path: FilePath) throws {
        try named("create directory", [path]) { try createDirectoryBody(path) }
    }

    public func copy(from source: FilePath, to destination: FilePath) throws {
        try named("copy", [source, destination]) { try copyBody(source, destination) }
    }

    public func copyTree(from source: FilePath, to destination: FilePath) throws {
        try named("copy tree", [source, destination]) {
            try copyTreeBody(source, destination)
        }
    }

    public func read(_ path: FilePath) throws -> [UInt8] {
        try named("read", [path]) { try readBody(path) }
    }

    public func readPrefix(_ path: FilePath, count: Int) throws -> [UInt8] {
        guard count >= 0 else {
            throw ActionFileSystemFailure.invalidReadCount(count)
        }
        return try readPrefixBody(path, count)
    }

    public func readSymbolicLink(_ path: FilePath) throws -> String {
        try readSymbolicLinkBody(path)
    }

    public func remove(_ path: FilePath) throws {
        try named("remove", [path]) { try removeBody(path) }
    }

    public func move(from source: FilePath, to destination: FilePath) throws {
        try named("move", [source, destination]) { try moveBody(source, destination) }
    }

    /// Gives every file beneath a root one modification time.
    ///
    /// Acquired content is identified by what it contains, never by when it
    /// was written, and a materialization records the moment it happened to
    /// run. Anything that carries that moment into a compiled product makes
    /// the product depend on when its inputs were fetched, which no second
    /// machine can reproduce.
    public func normalizeTimestamps(
        under root: FilePath,
        toSecondsSinceEpoch seconds: Int64
    ) throws {
        try named("normalize-timestamps", [root]) {
            try normalizeTimestampsBody(root, seconds)
        }
    }

    /// The entries directly inside a directory, without descending and without
    /// resolving a symbolic link to what it names.
    public func listDirectory(_ root: FilePath) throws -> [Entry] {
        try named("list-directory", [root]) { try listDirectoryBody(root) }
    }

    public func listRecursively(_ root: FilePath) throws -> [Entry] {
        try named("list", [root]) { try listRecursivelyBody(root) }
    }

    public func digest(file path: FilePath) throws -> ArtifactDigest {
        try digestFileBody(path)
    }

    public func digest(
        tree path: FilePath,
        excluding relativePaths: Set<String> = []
    ) throws -> ArtifactDigest {
        try digestTreeBody(path, relativePaths)
    }

    public func publishGeneration(
        candidate: FilePath,
        generation: FilePath,
        active: FilePath
    ) throws {
        try publishGenerationBody(candidate, generation, active)
    }

    public func pruneDirectories(_ plan: DirectoryRetentionPlan) throws {
        try pruneDirectoriesBody(plan)
    }

    public func replaceSymlink(at path: FilePath, target: String) throws {
        try named("replace symlink", [path, FilePath(target)]) {
            try replaceSymlinkBody(path, target)
        }
    }

    public func setPermissions(_ permissions: UInt16, for path: FilePath) throws {
        try named("set permissions", [path]) { try setPermissionsBody(path, permissions) }
    }

    public func write(_ bytes: [UInt8], to path: FilePath) throws {
        try named("write", [path]) { try writeBody(bytes, path) }
    }

    package func scoped(to effects: [ActionEffect]) -> ActionFileSystem {
        let require: @Sendable (ActionEffectAccess, FilePath) throws -> Void = {
            access, path in
            guard Self.permits(access, to: path, within: effects) else {
                throw ActionFileSystemFailure.undeclaredEffect(
                    access: access,
                    path: path)
            }
        }

        return ActionFileSystem(
            metadata: { path in
                try require(.read, path)
                return try metadataBody(path)
            },
            metadataNoFollow: { path in
                try require(.read, path)
                return try metadataNoFollowBody(path)
            },
            contentsEqual: { first, second in
                try require(.read, first)
                try require(.read, second)
                return try contentsEqualBody(first, second)
            },
            createDirectory: { path in
                try require(.write, path)
                try createDirectoryBody(path)
            },
            copy: { source, destination in
                try require(.read, source)
                try require(.write, destination)
                try copyBody(source, destination)
            },
            copyTree: { source, destination in
                try require(.read, source)
                try require(.write, destination)
                try copyTreeBody(source, destination)
            },
            read: { path in
                try require(.read, path)
                return try readBody(path)
            },
            readPrefix: { path, count in
                try require(.read, path)
                return try readPrefixBody(path, count)
            },
            readSymbolicLink: { path in
                try require(.read, path)
                return try readSymbolicLinkBody(path)
            },
            remove: { path in
                try require(.write, path)
                try removeBody(path)
            },
            move: { source, destination in
                try require(.write, source)
                try require(.write, destination)
                try moveBody(source, destination)
            },
            normalizeTimestamps: { root, seconds in
                try require(.write, root)
                try normalizeTimestampsBody(root, seconds)
            },
            listDirectory: { root in
                try require(.read, root)
                return try listDirectoryBody(root)
            },
            listRecursively: { root in
                try require(.read, root)
                return try listRecursivelyBody(root)
            },
            digestFile: { path in
                try require(.read, path)
                return try digestFileBody(path)
            },
            digestTree: { path, exclusions in
                try require(.read, path)
                return try digestTreeBody(path, exclusions)
            },
            publishGeneration: { candidate, generation, active in
                try require(.write, candidate)
                try require(.write, generation)
                try require(.write, active)
                try publishGenerationBody(candidate, generation, active)
            },
            pruneDirectories: { plan in
                for rule in plan.rules {
                    try require(.write, rule.root)
                    if let current = rule.current {
                        try require(.read, current)
                    }
                }
                try pruneDirectoriesBody(plan)
            },
            replaceSymlink: { path, target in
                try require(.write, path)
                try replaceSymlinkBody(path, target)
            },
            setPermissions: { path, permissions in
                try require(.write, path)
                try setPermissionsBody(path, permissions)
            },
            write: { bytes, path in
                try require(.write, path)
                try writeBody(bytes, path)
            })
    }

    private static func permits(
        _ requested: ActionEffectAccess,
        to path: FilePath,
        within effects: [ActionEffect]
    ) -> Bool {
        guard path.isAbsolute else { return false }
        return effects.contains { effect in
            guard effect.access.permits(requested) else { return false }
            return path.isContained(in: effect.scope.root)
        }
    }
}

extension ActionEffectAccess {
    fileprivate func permits(_ requested: ActionEffectAccess) -> Bool {
        switch (self, requested) {
        case (.readWrite, _), (.read, .read), (.write, .write):
            true
        case (.read, .write), (.read, .readWrite), (.write, .read),
            (.write, .readWrite):
            false
        }
    }
}

public enum ActionFileSystemFailure: Error, CustomStringConvertible, Sendable {
    case invalidReadCount(Int)
    case unavailable(String)
    case undeclaredEffect(access: ActionEffectAccess, path: FilePath)
    case operationFailed(operation: String, paths: [String], reason: String)

    public var description: String {
        switch self {
        case .invalidReadCount(let count):
            "action filesystem prefix-read count must be nonnegative; received \(count)"
        case .unavailable(let capability):
            "action filesystem capability '\(capability)' is unavailable"
        case .undeclaredEffect(let access, let path):
            "action attempted an undeclared \(access.rawValue) filesystem effect at '\(path)'"
        case .operationFailed(let operation, let paths, let reason):
            "action filesystem \(operation) failed: \(reason)\n"
                + paths.map { "  path: \($0)" }.joined(separator: "\n")
        }
    }
}
