import Foundation

public struct AndroidRuntimeProcessResult: Equatable, Sendable {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

public protocol AndroidRuntimeRunningProcess: Sendable {
    var processIdentifier: Int32? { get async }
    var isRunning: Bool { get async }

    func waitUntilReady() async throws
    func waitForExit() async throws -> AndroidRuntimeProcessResult
}

public protocol AndroidRuntimeKernelLog: AnyObject, Sendable {
    var slavePath: String { get }

    func checkHealth() throws
    func stop()
}

public struct AndroidRuntimeBinderDeviceNumber: Equatable, Sendable {
    public let major: UInt32
    public let minor: UInt32

    public init(major: UInt32, minor: UInt32) {
        self.major = major
        self.minor = minor
    }
}

public enum AndroidRuntimeCommandOutput: Equatable, Sendable {
    case inherited
    case file(URL)
}

public struct AndroidRuntimeCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: URL?
    public let capture: Bool
    public let environmentOverrides: [String: String]
    public let output: AndroidRuntimeCommandOutput?
    public let timeoutSeconds: Int?

    public init(
        executable: String,
        arguments: [String],
        directory: URL? = nil,
        capture: Bool = false,
        environmentOverrides: [String: String] = [:],
        output: AndroidRuntimeCommandOutput? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.capture = capture
        self.environmentOverrides = environmentOverrides
        self.output = output
        self.timeoutSeconds = timeoutSeconds
    }
}

public protocol AndroidRuntimeHost: Sendable {
    associatedtype RunningProcess: AndroidRuntimeRunningProcess
    associatedtype KernelLog: AndroidRuntimeKernelLog

    func execute(_ command: AndroidRuntimeCommand) async throws -> String

    func withRunningProcess<Value: Sendable>(
        _ command: AndroidRuntimeCommand,
        _ body: @escaping @Sendable (RunningProcess) async throws -> Value
    ) async throws -> Value

    func makeKernelLog(output: URL) throws -> KernelLog

    func addBinderDevice(
        control: URL,
        name: String
    ) throws -> AndroidRuntimeBinderDeviceNumber
}

extension AndroidRuntimeHost {
    @discardableResult
    public func run(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        capture: Bool = false,
        environmentOverrides: [String: String] = [:],
        output: AndroidRuntimeCommandOutput? = nil,
        timeoutSeconds: Int? = nil
    ) async throws -> String {
        try await execute(AndroidRuntimeCommand(
            executable: executable,
            arguments: arguments,
            directory: directory,
            capture: capture,
            environmentOverrides: environmentOverrides,
            output: output,
            timeoutSeconds: timeoutSeconds))
    }

    public func withRunningCommand<Value: Sendable>(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        environmentOverrides: [String: String] = [:],
        output: AndroidRuntimeCommandOutput = .inherited,
        _ body: @escaping @Sendable (RunningProcess) async throws -> Value
    ) async throws -> Value {
        try await withRunningProcess(
            AndroidRuntimeCommand(
                executable: executable,
                arguments: arguments,
                directory: directory,
                environmentOverrides: environmentOverrides,
                output: output),
            body)
    }
}
