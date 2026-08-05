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

public enum ActionIdentityEncodingFailure: Error, CustomStringConvertible, Sendable {
    case invalidTag(UInt64)
    case duplicateTag(UInt64)

    public var description: String {
        switch self {
        case .invalidTag(let tag):
            "action identity tag must be positive; received \(tag)"
        case .duplicateTag(let tag):
            "action identity tag \(tag) was encoded more than once"
        }
    }
}

public struct ActionIdentityEncoder: Sendable {
    private enum Value: Sendable {
        case bytes([UInt8])
        case integer(UInt64)
        case string(String)
    }

    private var fields: [UInt64: Value] = [:]
    private var failure: ActionIdentityEncodingFailure?
    public let identityPathMap: IdentityPathMap

    public init(identityPathMap: IdentityPathMap = .empty) {
        self.identityPathMap = identityPathMap
    }

    public mutating func append(tag: UInt64, string: String) {
        append(
            tag: tag,
            value: .string(identityPathMap.canonicalize(string)))
    }

    public mutating func append(tag: UInt64, bytes: [UInt8]) {
        append(tag: tag, value: .bytes(bytes))
    }

    public mutating func append(tag: UInt64, integer: UInt64) {
        append(tag: tag, value: .integer(integer))
    }

    public mutating func append<Identity: ColliderActionIdentity>(
        tag: UInt64,
        nested identity: Identity
    ) {
        var nested = ActionIdentityEncoder(identityPathMap: identityPathMap)
        identity.encode(into: &nested)
        if let failure = nested.failure {
            self.failure = failure
            return
        }
        append(tag: tag, value: .bytes(nested.canonicalBytes()))
    }

    public func encodedBytes() throws -> [UInt8] {
        if let failure { throw failure }
        return canonicalBytes()
    }

    private func canonicalBytes() -> [UInt8] {
        var bytes: [UInt8] = []
        for tag in fields.keys.sorted() {
            guard let value = fields[tag] else { continue }
            bytes += actionIdentityIntegerBytes(tag)
            switch value {
            case .bytes(let value):
                bytes.append(1)
                bytes += actionIdentityIntegerBytes(UInt64(value.count))
                bytes += value
            case .integer(let value):
                bytes.append(2)
                bytes += actionIdentityIntegerBytes(8)
                bytes += actionIdentityIntegerBytes(value)
            case .string(let value):
                let value = Array(value.utf8)
                bytes.append(3)
                bytes += actionIdentityIntegerBytes(UInt64(value.count))
                bytes += value
            }
        }
        return bytes
    }

    private mutating func append(tag: UInt64, value: Value) {
        guard failure == nil else { return }
        guard tag > 0 else {
            failure = .invalidTag(tag)
            return
        }
        guard fields[tag] == nil else {
            failure = .duplicateTag(tag)
            return
        }
        fields[tag] = value
    }
}

private func actionIdentityIntegerBytes(_ value: UInt64) -> [UInt8] {
    (0..<8).reversed().map { shift in
        UInt8(truncatingIfNeeded: value >> UInt64(shift * 8))
    }
}

public protocol ColliderActionIdentity: Hashable, Sendable {
    func encode(into encoder: inout ActionIdentityEncoder)
}

public struct DownloadActionIdentity: ColliderActionIdentity {
    public let specification: DownloadSpec
    public let destination: FilePath

    public init(specification: DownloadSpec, destination: FilePath) {
        self.specification = specification
        self.destination = destination
    }

    public func encode(into encoder: inout ActionIdentityEncoder) {
        encoder.append(tag: 1, string: specification.url.absoluteString)
        encoder.append(tag: 2, bytes: specification.expectedDigest.bytes)
        encoder.append(tag: 3, string: destination.string)

        var redirectOrigins = CanonicalDigestEncoder(
            identityPathMap: encoder.identityPathMap)
        for origin in specification.permittedRedirectOrigins.sorted() {
            redirectOrigins.append(tag: 1, string: origin)
        }
        encoder.append(tag: 4, bytes: redirectOrigins.bytes)
        encoder.append(
            tag: 5,
            integer: UInt64(specification.maximumResponseSize))

        var mediaTypes = CanonicalDigestEncoder(
            identityPathMap: encoder.identityPathMap)
        for mediaType in specification.acceptedMediaTypes.map({ $0.lowercased() }).sorted() {
            mediaTypes.append(tag: 1, string: mediaType)
        }
        encoder.append(tag: 6, bytes: mediaTypes.bytes)
        encoder.append(tag: 7, integer: specification.requestTimeoutSeconds)
        encoder.append(tag: 8, integer: specification.inactivityTimeoutSeconds)
        encoder.append(tag: 9, integer: UInt64(specification.maximumRedirects))
        encoder.append(tag: 10, integer: UInt64(specification.maximumRetries))
        encoder.append(tag: 11, string: specification.resumption.rawValue)
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

    @discardableResult
    public func run(_ execution: OCIExecution) async throws -> CommandResult {
        try await runBody(execution)
    }
}

public enum ActionContainerExecutorFailure: Error, Sendable {
    case unavailable
}

public struct OCIImagePreparationActionIdentity: ColliderActionIdentity {
    public let preparation: OCIImagePreparation

    public init(_ preparation: OCIImagePreparation) {
        self.preparation = preparation
    }

    public func encode(into encoder: inout ActionIdentityEncoder) {
        encoder.append(
            tag: 1,
            string: preparation.executionPlatform.environment.rawValue)
        encoder.append(
            tag: 2,
            string: preparation.executionPlatform.operatingSystem.rawValue)
        encoder.append(
            tag: 3,
            string: preparation.executionPlatform.architecture.rawValue)
        encoder.append(tag: 4, string: preparation.context.string)
        encoder.append(tag: 5, string: preparation.containerFile.string)
        encoder.append(tag: 6, string: preparation.imageID.string)
        encoder.append(tag: 7, string: preparation.imageName)
    }
}

public struct OCIExecutionActionIdentity: ColliderActionIdentity {
    public let execution: OCIExecution

    public init(_ execution: OCIExecution) {
        self.execution = execution
    }

    public func encode(into encoder: inout ActionIdentityEncoder) {
        encoder.append(tag: 1, string: execution.executionPlatform.environment.rawValue)
        encoder.append(tag: 2, string: execution.executionPlatform.operatingSystem.rawValue)
        encoder.append(tag: 3, string: execution.executionPlatform.architecture.rawValue)
        encoder.append(tag: 4, string: execution.artifactTarget.operatingSystem.rawValue)
        encoder.append(tag: 5, string: execution.artifactTarget.architecture.rawValue)
        encoder.append(tag: 6, string: execution.artifactTarget.abi ?? "")
        encoder.append(
            tag: 7,
            integer: UInt64(execution.artifactTarget.androidAPILevel ?? 0))
        encoder.append(tag: 8, string: execution.imageID.string)
        encoder.append(tag: 9, string: execution.hostname)
        encoder.append(tag: 10, string: execution.workingDirectory)
        encoder.append(tag: 11, string: execution.hostWorkingDirectory.string)

        var mounts = CanonicalDigestEncoder(
            identityPathMap: encoder.identityPathMap)
        for mount in execution.mounts {
            mounts.append(tag: 1, string: mount.source.string)
            mounts.append(tag: 2, string: mount.target)
            mounts.append(tag: 3, string: mount.access.rawValue)
        }
        encoder.append(tag: 12, bytes: mounts.bytes)
        encoder.append(tag: 13, string: execution.temporaryDirectory?.string ?? "")
        encoder.append(tag: 14, string: execution.networkPolicy.rawValue)
        encoder.append(tag: 15, integer: UInt64(execution.userPolicy.userID))
        encoder.append(tag: 16, integer: UInt64(execution.userPolicy.groupID))
        encoder.append(tag: 17, string: execution.capabilityPolicy.rawValue)
        encoder.append(tag: 18, string: execution.privilegePolicy.rawValue)
        encoder.append(tag: 19, string: execution.processFilesystemPolicy.rawValue)
        encoder.append(tag: 20, string: execution.intelBinaryTranslationPolicy.rawValue)
        encoder.append(tag: 21, integer: UInt64(execution.resourceLimits.cpuCount ?? 0))
        encoder.append(tag: 22, integer: execution.resourceLimits.memoryBytes ?? 0)
        encoder.append(tag: 23, integer: UInt64(execution.resourceLimits.processCount))

        var containerEnvironment = CanonicalDigestEncoder(
            identityPathMap: encoder.identityPathMap)
        for (name, value) in execution.containerEnvironment.sorted(by: {
            $0.key < $1.key
        }) {
            containerEnvironment.append(tag: 1, string: name)
            containerEnvironment.append(tag: 2, string: value)
        }
        encoder.append(tag: 24, bytes: containerEnvironment.bytes)

        var command = CanonicalDigestEncoder(
            identityPathMap: encoder.identityPathMap)
        for argument in execution.command {
            command.append(tag: 1, string: argument)
        }
        encoder.append(tag: 25, bytes: command.bytes)
        encoder.append(tag: 26, string: ociActionOutputIdentity(execution.output))
    }
}

public struct OCIExecutionPipelineIdentity: ColliderActionIdentity {
    public let executions: [OCIExecution]

    public init(_ executions: [OCIExecution]) {
        self.executions = executions
    }

    public func encode(into encoder: inout ActionIdentityEncoder) {
        encoder.append(tag: 1, integer: UInt64(executions.count))
        for (index, execution) in executions.enumerated() {
            encoder.append(
                tag: UInt64(index + 2),
                nested: OCIExecutionActionIdentity(execution))
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
        var cpuCount: UInt32? = 0
        var memoryBytes: UInt64? = 0
        for execution in executions {
            for effect in ociActionRequirements(execution: execution).effects
            where !effects.contains(effect) {
                effects.append(effect)
            }
            cpuCount = maximumResource(cpuCount, execution.resourceLimits.cpuCount)
            memoryBytes = maximumResource(
                memoryBytes,
                execution.resourceLimits.memoryBytes)
        }

        self.executions = executions
        identity = OCIExecutionPipelineIdentity(executions)
        requirements = ActionRequirements(
            effects: effects,
            resources: ActionResourceRequest(
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                exclusive: false),
            networkAccess: executions.contains {
                $0.networkPolicy == .externalEnabled
            } ? .unrestricted : .none,
            executionPlatform: first.executionPlatform,
            artifactTarget: first.artifactTarget)
        environment = first.environment
    }

    public func execute(in context: ActionContext) async throws {
        for execution in executions {
            try context.cancellation.check()
            try await context.containers.run(execution)
        }
    }
}

private func maximumResource<Value: FixedWidthInteger>(
    _ lhs: Value?,
    _ rhs: Value?
) -> Value? {
    guard let lhs, let rhs else { return nil }
    return max(lhs, rhs)
}

public func ociActionRequirements(
    execution: OCIExecution
) -> ActionRequirements {
    var effects = [
        ActionEffect(.read, scope: .input(execution.imageID))
    ]
    for mount in execution.mounts {
        let effect = ActionEffect(
            mount.access == .readOnly ? .read : .readWrite,
            scope: mount.access == .readOnly
                ? .input(mount.source) : .scratch(mount.source))
        if !effects.contains(effect) { effects.append(effect) }
    }
    if let temporaryDirectory = execution.temporaryDirectory {
        let effect = ActionEffect(
            .readWrite,
            scope: .scratch(temporaryDirectory))
        if !effects.contains(effect) { effects.append(effect) }
    }
    return ActionRequirements(
        effects: effects,
        resources: ActionResourceRequest(
            cpuCount: execution.resourceLimits.cpuCount,
            memoryBytes: execution.resourceLimits.memoryBytes,
            exclusive: false),
        networkAccess:
            execution.networkPolicy == .externalEnabled ? .unrestricted : .none,
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
        resources: .fullHostExclusive,
        networkAccess: .unrestricted,
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

public struct ActionRequirements: Hashable, Sendable {
    public let tools: [ActionToolRequirement]
    public let effects: [ActionEffect]
    public let resources: ActionResourceRequest
    public let networkAccess: ActionNetworkAccess
    public let executionPlatform: ExecutionPlatform
    public let artifactTarget: ArtifactTarget?

    public init(
        tools: [ActionToolRequirement] = [],
        effects: [ActionEffect] = [],
        resources: ActionResourceRequest = .lightweight,
        networkAccess: ActionNetworkAccess = .none,
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget? = nil
    ) {
        self.tools = tools
        self.effects = effects
        self.resources = resources
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

public struct ActionResourceRequest: Hashable, Sendable {
    public let cpuCount: UInt32?
    public let memoryBytes: UInt64?
    public let ioWeight: UInt32?
    public let exclusive: Bool

    public init(
        cpuCount: UInt32?,
        memoryBytes: UInt64?,
        ioWeight: UInt32? = 1,
        exclusive: Bool
    ) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.ioWeight = ioWeight
        self.exclusive = exclusive
    }

    public static let lightweight = ActionResourceRequest(
        cpuCount: 1,
        memoryBytes: 512 * 1_024 * 1_024,
        ioWeight: 1,
        exclusive: false)

    public static let fullHostExclusive = ActionResourceRequest(
        cpuCount: nil,
        memoryBytes: nil,
        ioWeight: nil,
        exclusive: true)
}

public enum ActionDeclarationFailure: Error, CustomStringConvertible, Sendable {
    case emptyKind
    case duplicateToolName(String)
    case conflictingToolRole(CommandSpec.Executable)
    case duplicateEffect(ActionEffect)
    case relativeEffectRoot(FilePath)

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
        }
    }
}

public protocol ColliderAction: Sendable {
    associatedtype Identity: ColliderActionIdentity

    static var kind: ActionKind { get }

    var identity: Identity { get }
    var requirements: ActionRequirements { get }
    var environment: [String: String] { get }

    func execute(in context: ActionContext) async throws
    func validateOutputs(using files: ActionFileSystem) throws
}

extension ColliderAction {
    public var environment: [String: String] { [:] }
    public func validateOutputs(using _: ActionFileSystem) throws {}
}

public struct AnyColliderAction: Hashable, Sendable {
    public let kind: ActionKind
    public let implementationType: String
    public let identity: [UInt8]
    public let requirements: ActionRequirements
    public let environment: [String: String]

    private let body: @Sendable (ActionContext) async throws -> Void
    private let validationBody: @Sendable (ActionFileSystem) throws -> Void
    private let identityBody: @Sendable (IdentityPathMap) throws -> [UInt8]

    public init<Action: ColliderAction>(_ action: Action) throws {
        try Self.validate(kind: Action.kind, requirements: action.requirements)
        var encoder = ActionIdentityEncoder()
        action.identity.encode(into: &encoder)
        kind = Action.kind
        implementationType = String(reflecting: Action.self)
        identity = try encoder.encodedBytes()
        identityBody = { pathMap in
            var encoder = ActionIdentityEncoder(identityPathMap: pathMap)
            action.identity.encode(into: &encoder)
            return try encoder.encodedBytes()
        }
        requirements = action.requirements
        environment = action.environment
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
        }
    }

    public func execute(in context: ActionContext) async throws {
        try await body(context)
    }

    public func validateOutputs(using files: ActionFileSystem) throws {
        try validationBody(files)
    }

    public func identity(using pathMap: IdentityPathMap) throws -> [UInt8] {
        try identityBody(pathMap)
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

public struct ActionContext: Sendable {
    public let files: ActionFileSystem
    public let cancellation: ActionCancellation
    public let logger: ActionLogger
    public let commands: ActionCommandExecutor
    public let downloads: ActionDownloader
    public let containers: ActionContainerExecutor

    public init(
        files: ActionFileSystem,
        cancellation: ActionCancellation,
        logger: ActionLogger,
        commands: ActionCommandExecutor,
        downloads: ActionDownloader,
        containers: ActionContainerExecutor = ActionContainerExecutor()
    ) {
        self.files = files
        self.cancellation = cancellation
        self.logger = logger
        self.commands = commands
        self.downloads = downloads
        self.containers = containers
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
        try metadataBody(path)
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

    public func createDirectory(_ path: FilePath) throws {
        try createDirectoryBody(path)
    }

    public func copy(from source: FilePath, to destination: FilePath) throws {
        try copyBody(source, destination)
    }

    public func copyTree(from source: FilePath, to destination: FilePath) throws {
        try copyTreeBody(source, destination)
    }

    public func read(_ path: FilePath) throws -> [UInt8] {
        try readBody(path)
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
        try removeBody(path)
    }

    public func move(from source: FilePath, to destination: FilePath) throws {
        try moveBody(source, destination)
    }

    public func listRecursively(_ root: FilePath) throws -> [Entry] {
        try listRecursivelyBody(root)
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
        try replaceSymlinkBody(path, target)
    }

    public func setPermissions(_ permissions: UInt16, for path: FilePath) throws {
        try setPermissionsBody(path, permissions)
    }

    public func write(_ bytes: [UInt8], to path: FilePath) throws {
        try writeBody(bytes, path)
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
        let path = path.lexicallyNormalized().string
        return effects.contains { effect in
            guard effect.access.permits(requested) else { return false }
            let root = effect.scope.root.lexicallyNormalized().string
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
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

    public var description: String {
        switch self {
        case .invalidReadCount(let count):
            "action filesystem prefix-read count must be nonnegative; received \(count)"
        case .unavailable(let capability):
            "action filesystem capability '\(capability)' is unavailable"
        case .undeclaredEffect(let access, let path):
            "action attempted an undeclared \(access.rawValue) filesystem effect at '\(path)'"
        }
    }
}
