import SystemPackage

public protocol ColliderActionIdentity: Hashable, Sendable {
    func encode(into encoder: inout CanonicalDigestEncoder)
}

public protocol ColliderAction: Sendable {
    associatedtype Identity: ColliderActionIdentity

    static var kind: String { get }

    var identity: Identity { get }
    var environment: [String: String] { get }

    func execute(in context: ActionContext) async throws
}

extension ColliderAction {
    public var environment: [String: String] { [:] }
}

public struct AnyColliderAction: Hashable, Sendable {
    public let kind: String
    public let implementationType: String
    public let identity: [UInt8]
    public let environment: [String: String]

    private let body: @Sendable (ActionContext) async throws -> Void

    public init<Action: ColliderAction>(_ action: Action) {
        var encoder = CanonicalDigestEncoder()
        action.identity.encode(into: &encoder)
        kind = Action.kind
        implementationType = String(reflecting: Action.self)
        identity = encoder.bytes
        environment = action.environment
        body = { context in
            try await action.execute(in: context)
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
            && lhs.environment == rhs.environment
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(identity)
        hasher.combine(environment)
    }
}

public struct ActionContext: Sendable {
    public let files: ActionFileSystem

    private let executeBody: @Sendable (CommandSpec) async throws -> CommandResult

    public init(
        files: ActionFileSystem,
        execute: @escaping @Sendable (CommandSpec) async throws -> CommandResult
    ) {
        self.files = files
        executeBody = execute
    }

    public func execute(_ command: CommandSpec) async throws -> CommandResult {
        try await executeBody(command)
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
