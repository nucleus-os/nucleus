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
  public let identity: [UInt8]
  public let environment: [String: String]

  private let body: @Sendable (ActionContext) async throws -> Void

  public init<Action: ColliderAction>(_ action: Action) {
    var encoder = CanonicalDigestEncoder()
    action.identity.encode(into: &encoder)
    kind = Action.kind
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

    public init(type: FileType, ownerExecutable: Bool) {
      self.type = type
      self.ownerExecutable = ownerExecutable
    }
  }

  private let metadataBody: @Sendable (FilePath) throws -> Metadata?
  private let createDirectoryBody: @Sendable (FilePath) throws -> Void
  private let copyBody: @Sendable (FilePath, FilePath) throws -> Void
  private let setPermissionsBody: @Sendable (FilePath, UInt16) throws -> Void
  private let writeBody: @Sendable ([UInt8], FilePath) throws -> Void

  public init(
    metadata: @escaping @Sendable (FilePath) throws -> Metadata?,
    createDirectory: @escaping @Sendable (FilePath) throws -> Void,
    copy: @escaping @Sendable (FilePath, FilePath) throws -> Void,
    setPermissions: @escaping @Sendable (FilePath, UInt16) throws -> Void,
    write: @escaping @Sendable ([UInt8], FilePath) throws -> Void
  ) {
    metadataBody = metadata
    createDirectoryBody = createDirectory
    copyBody = copy
    setPermissionsBody = setPermissions
    writeBody = write
  }

  public func metadata(for path: FilePath) throws -> Metadata? {
    try metadataBody(path)
  }

  public func createDirectory(_ path: FilePath) throws {
    try createDirectoryBody(path)
  }

  public func copy(from source: FilePath, to destination: FilePath) throws {
    try copyBody(source, destination)
  }

  public func setPermissions(_ permissions: UInt16, for path: FilePath) throws {
    try setPermissionsBody(path, permissions)
  }

  public func write(_ bytes: [UInt8], to path: FilePath) throws {
    try writeBody(bytes, path)
  }
}
