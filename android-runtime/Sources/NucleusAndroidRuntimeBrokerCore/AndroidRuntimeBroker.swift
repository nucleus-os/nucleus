import Foundation
import NucleusAndroidRuntimeBridgeProtocol
import NucleusAndroidRuntimeCore

public struct AndroidRuntimeBrokerConfiguration: Sendable {
    public let androidRoot: URL
    public let runDirectory: URL
    public let waylandSocket: String
    public let gfxstreamBrokerExecutable: URL
    public let displayHostExecutable: URL
    public let privilegedHelperExecutable: URL
    public let swiftRuntime: AndroidSwiftRuntime
    public let timeoutSeconds: UInt32

    public init(
        androidRoot: URL,
        runDirectory: URL,
        waylandSocket: String,
        gfxstreamBrokerExecutable: URL,
        displayHostExecutable: URL,
        privilegedHelperExecutable: URL,
        swiftRuntime: AndroidSwiftRuntime,
        timeoutSeconds: UInt32
    ) throws {
        for path in [
            androidRoot,
            runDirectory,
            gfxstreamBrokerExecutable,
            displayHostExecutable,
            privilegedHelperExecutable,
            swiftRuntime.libraryRoot,
            swiftRuntime.loaderSearchDirectory,
        ] where !path.path.hasPrefix("/") {
            throw AndroidRuntimeFailure(
                "Android runtime paths must be absolute")
        }
        guard !waylandSocket.isEmpty,
            !waylandSocket.contains("/"),
            !waylandSocket.contains("\0"),
            timeoutSeconds > 0
        else {
            throw AndroidRuntimeFailure(
                "Android runtime Wayland/timeout configuration is invalid")
        }
        self.androidRoot = androidRoot
        self.runDirectory = runDirectory
        self.waylandSocket = waylandSocket
        self.gfxstreamBrokerExecutable = gfxstreamBrokerExecutable
        self.displayHostExecutable = displayHostExecutable
        self.privilegedHelperExecutable = privilegedHelperExecutable
        self.swiftRuntime = swiftRuntime
        self.timeoutSeconds = timeoutSeconds
    }
}
public func runAndroidRuntimeBroker<
    RuntimeHost: AndroidRuntimeHost
>(
    configuration: AndroidRuntimeBrokerConfiguration,
    host runtimeHost: RuntimeHost,
    environment: [String: String]
) async throws {
    let layout = AndroidRuntimeLayout(
        androidRoot: configuration.androidRoot,
        runDirectory: configuration.runDirectory,
        gfxstreamBrokerExecutable:
            configuration.gfxstreamBrokerExecutable,
        displayHostExecutable: configuration.displayHostExecutable)
    for executable in [
        configuration.gfxstreamBrokerExecutable,
        configuration.displayHostExecutable,
        configuration.privilegedHelperExecutable,
    ] where !FileManager.default.isExecutableFile(atPath: executable.path) {
        throw AndroidRuntimeFailure(
            "Android runtime executable is missing: \(executable.path)")
    }
    for input in [
        layout.appArmorProfile,
        layout.seccompProfile,
        layout.provenance,
        layout.hostTools.appendingPathComponent("avbtool"),
        layout.hostTools.appendingPathComponent("deapexer"),
        layout.signingIdentity.appendingPathComponent("releasekey.pem"),
    ] where !FileManager.default.fileExists(atPath: input.path) {
        throw AndroidRuntimeFailure(
            "Android runtime input is missing: \(input.path)")
    }
    let provenance = try await validateAndroidRuntimeImages(
        layout: layout,
        using: runtimeHost)
    let host = try await resolveAndroidRuntimeHostConfiguration(
        using: runtimeHost,
        environment: environment)
    let session = AndroidRuntimeSession(
        context: runtimeHost,
        layout: layout,
        host: host,
        privilegedHelperExecutable:
            configuration.privilegedHelperExecutable.path,
        swiftRuntime: configuration.swiftRuntime,
        dataProvenanceKey:
            provenance.sourceManifestSHA256
            + "-"
            + provenance.productTreeSHA256,
        gfxstreamBrokerEnvironment: [:])
    do {
        try await session.initializeDiagnostics()
        try await session.prepare()
        try await session.mountImages(provenance.images)
        try await session.mountApexes()
        try await session.createBinderDevices()
        try await session.writeConfiguration()
        let bridge = try AndroidRuntimeBridgeServer(
            socketPath: layout.runtimeBridgeSocket,
            expectedUserID: host.subordinateUID + 1_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await bridge.run { _ in }
            }
            group.addTask {
                try await session.runProcesses(
                    timeoutSeconds: configuration.timeoutSeconds,
                    waylandRuntimeDirectory:
                        configuration.runDirectory,
                    waylandSocket: configuration.waylandSocket,
                    lifetime: .untilCancellation)
            }
            guard try await group.next() != nil else {
                throw AndroidRuntimeFailure(
                    "Android runtime service group ended unexpectedly")
            }
            group.cancelAll()
            while let _ = try await group.next() {}
        }
        await session.cleanup()
    } catch {
        await session.cleanup()
        await session.printFailureDiagnostics()
        throw error
    }
}
