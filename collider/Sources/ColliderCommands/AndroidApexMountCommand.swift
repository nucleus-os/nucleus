import ArgumentParser
import ColliderRuntime
import Foundation

let androidApexMountCommandName = "__android-apex-mount"

struct AndroidApexMountPrivilegedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: androidApexMountCommandName,
        abstract: "Perform one validated pre-APEX payload mount.",
        shouldDisplay: false)

    @Option(name: .customLong("root-file-system"))
    var rootFileSystem: String

    @Option
    var source: String

    @Option
    var target: String

    @Option
    var payloadFileSystem: String

    @Option
    var payloadOffset: UInt64

    mutating func validate() throws {
        do {
            _ = try request()
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    mutating func run() throws {
        try request().mount()
    }

    private func request() throws -> AndroidApexMountRequest {
        guard let payloadFileSystem = AndroidApexPayloadFileSystem(
            rawValue: payloadFileSystem)
        else {
            throw ValidationError(
                "unsupported APEX payload filesystem: \(payloadFileSystem)")
        }
        return try AndroidApexMountRequest(
            rootFileSystem: rootFileSystem,
            source: source,
            target: target,
            payloadFileSystem: payloadFileSystem,
            payloadOffset: payloadOffset)
    }
}

struct AndroidApexMountInvocation: Equatable {
    let executable: String
    let arguments: [String]

    init(
        colliderExecutable: String,
        request: AndroidApexMountRequest
    ) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            colliderExecutable,
            androidApexMountCommandName,
            "--root-file-system",
            request.rootFileSystem,
            "--source",
            request.source,
            "--target",
            request.target,
            "--payload-file-system",
            request.payloadFileSystem.rawValue,
            "--payload-offset",
            String(request.payloadOffset),
        ]
    }
}

func currentColliderExecutable() throws -> String {
#if os(Linux)
    let path = try FileManager.default.destinationOfSymbolicLink(
        atPath: "/proc/self/exe")
#else
    let argument = CommandLine.arguments[0]
    let path = URL(
        fileURLWithPath: argument,
        relativeTo: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
    ).standardizedFileURL.path
#endif
    guard path.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: path)
    else {
        throw WorkspaceFailure.message(
            "cannot resolve the running Collider executable")
    }
    return path
}
