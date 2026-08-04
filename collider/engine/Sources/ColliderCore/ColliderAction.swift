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

    public init() {}

    public mutating func append(tag: UInt64, string: String) {
        append(tag: tag, value: .string(string))
    }

    public mutating func append(tag: UInt64, bytes: [UInt8]) {
        append(tag: tag, value: .bytes(bytes))
    }

    public mutating func append(tag: UInt64, integer: UInt64) {
        append(tag: tag, value: .integer(integer))
    }

    public func encodedBytes() throws -> [UInt8] {
        if let failure { throw failure }
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

    public init(
        tools: [ActionToolRequirement] = [],
        effects: [ActionEffect] = []
    ) {
        self.tools = tools
        self.effects = effects
    }
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
}

extension ColliderAction {
    public var requirements: ActionRequirements { ActionRequirements() }
    public var environment: [String: String] { [:] }
}

public struct AnyColliderAction: Hashable, Sendable {
    public let kind: ActionKind
    public let implementationType: String
    public let identity: [UInt8]
    public let requirements: ActionRequirements
    public let environment: [String: String]

    private let body: @Sendable (ActionContext) async throws -> Void

    public init<Action: ColliderAction>(_ action: Action) throws {
        try Self.validate(kind: Action.kind, requirements: action.requirements)
        var encoder = ActionIdentityEncoder()
        action.identity.encode(into: &encoder)
        kind = Action.kind
        implementationType = String(reflecting: Action.self)
        identity = try encoder.encodedBytes()
        requirements = action.requirements
        environment = action.environment
        body = { context in
            try await action.execute(in: context)
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

    public init(
        files: ActionFileSystem,
        cancellation: ActionCancellation,
        logger: ActionLogger,
        commands: ActionCommandExecutor,
        downloads: ActionDownloader
    ) {
        self.files = files
        self.cancellation = cancellation
        self.logger = logger
        self.commands = commands
        self.downloads = downloads
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
    private let removeBody: @Sendable (FilePath) throws -> Void
    private let moveBody: @Sendable (FilePath, FilePath) throws -> Void
    private let listRecursivelyBody: @Sendable (FilePath) throws -> [Entry]
    private let digestFileBody: @Sendable (FilePath) throws -> ArtifactDigest
    private let digestTreeBody: @Sendable (FilePath, Set<String>) throws -> ArtifactDigest
    private let publishGenerationBody: @Sendable (FilePath, FilePath, FilePath) throws -> Void
    private let pruneDirectoriesBody: @Sendable (DirectoryRetentionPlan) throws -> Void
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
        removeBody = remove
        moveBody = move
        listRecursivelyBody = listRecursively
        digestFileBody = digestFile
        digestTreeBody = digestTree
        publishGenerationBody = publishGeneration
        pruneDirectoriesBody = pruneDirectories
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

    public func setPermissions(_ permissions: UInt16, for path: FilePath) throws {
        try setPermissionsBody(path, permissions)
    }

    public func write(_ bytes: [UInt8], to path: FilePath) throws {
        try writeBody(bytes, path)
    }
}

public enum ActionFileSystemFailure: Error, CustomStringConvertible, Sendable {
    case unavailable(String)

    public var description: String {
        switch self {
        case .unavailable(let capability):
            "action filesystem capability '\(capability)' is unavailable"
        }
    }
}
