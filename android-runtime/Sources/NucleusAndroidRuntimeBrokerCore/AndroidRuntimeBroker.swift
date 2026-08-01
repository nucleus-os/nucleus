import Foundation
import Glibc
internal import NucleusAndroidRuntimeBridgeProtocol
import NucleusAndroidRuntimeCore

package struct AndroidRuntimeBrokerConfiguration: Sendable {
    package let androidRoot: URL
    package let sessionRuntimeDirectory: URL
    package let diagnosticsRunDirectory: URL
    package let waylandSocket: String
    package let gfxstreamBrokerExecutable: URL
    package let displayHostExecutable: URL
    package let privilegedHelperExecutable: URL
    package let swiftRuntime: AndroidSwiftRuntime
    package let timeoutSeconds: UInt32
    package let gfxstreamBrokerEnvironment: [String: String]

    package init(
        androidRoot: URL,
        sessionRuntimeDirectory: URL,
        diagnosticsRunDirectory: URL,
        waylandSocket: String,
        gfxstreamBrokerExecutable: URL,
        displayHostExecutable: URL,
        privilegedHelperExecutable: URL,
        swiftRuntime: AndroidSwiftRuntime,
        timeoutSeconds: UInt32,
        gfxstreamBrokerEnvironment: [String: String] = [:]
    ) throws {
        for path in [
            androidRoot,
            sessionRuntimeDirectory,
            diagnosticsRunDirectory,
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
        self.sessionRuntimeDirectory = sessionRuntimeDirectory
        self.diagnosticsRunDirectory = diagnosticsRunDirectory
        self.waylandSocket = waylandSocket
        self.gfxstreamBrokerExecutable = gfxstreamBrokerExecutable
        self.displayHostExecutable = displayHostExecutable
        self.privilegedHelperExecutable = privilegedHelperExecutable
        self.swiftRuntime = swiftRuntime
        self.timeoutSeconds = timeoutSeconds
        self.gfxstreamBrokerEnvironment = gfxstreamBrokerEnvironment
    }
}
package func runAndroidRuntimeBroker<
    RuntimeHost: AndroidRuntimeHost
>(
    configuration: AndroidRuntimeBrokerConfiguration,
    host runtimeHost: RuntimeHost,
    environment: [String: String]
) async throws {
    let layout = AndroidRuntimeLayout(
        androidRoot: configuration.androidRoot,
        diagnosticsRunDirectory:
            configuration.diagnosticsRunDirectory,
        gfxstreamBrokerExecutable:
            configuration.gfxstreamBrokerExecutable,
        displayHostExecutable: configuration.displayHostExecutable)
    let progress = try initializeAndroidRuntimeDiagnostics(
        layout: layout)
    try progress.record("images.validation-started")
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
    try progress.record("images.validated")
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
        gfxstreamBrokerEnvironment:
            configuration.gfxstreamBrokerEnvironment,
        progress: progress)
    do {
        try await session.prepare()
        try await session.mountImages(provenance.images)
        try await session.mountApexes()
        try await session.createBinderDevices()
        try await session.writeConfiguration()
        let bridge = try AndroidRuntimeBridgeServer(
            socketPath: layout.runtimeBridgeSocket,
            expectedUserID:
                host.subordinateUID
                + AndroidRuntimeBridgeProtocol.androidUserID)
        let displayInteraction = try AndroidDisplayInteractionServer(
            socketPath: layout.displayInputSocket,
            expectedUserID: getuid())
        try await session.recordRuntimeBridgeListener()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await bridge.run { event in
                    if case .cursorShapeChanged(_, let update) = event {
                        try? displayInteraction.send(update)
                    }
                    await recordRuntimeBridgeEvent(
                        event,
                        session: session)
                }
            }
            group.addTask {
                try await displayInteraction.run { event in
                    switch event {
                    case .input(let input):
                        try bridge.send(input)
                    }
                }
            }
            group.addTask {
                try await session.runProcesses(
                    timeoutSeconds: configuration.timeoutSeconds,
                    waylandRuntimeDirectory:
                        configuration.sessionRuntimeDirectory,
                    waylandSocket: configuration.waylandSocket)
            }
            guard try await group.next() != nil else {
                throw AndroidRuntimeFailure(
                    "Android runtime service group ended unexpectedly")
            }
            group.cancelAll()
            while (try await group.next()) != nil {}
        }
        try await session.cleanup()
    } catch is CancellationError {
        await session.recordCancellation()
        do {
            try await session.cleanup()
        } catch let cleanupError {
            throw AndroidRuntimeFailure(
                "Android runtime cancellation cleanup failed: \(cleanupError)")
        }
        throw CancellationError()
    } catch let runtimeError {
        await session.recordFailure("\(runtimeError)")
        do {
            try await session.cleanup()
        } catch let cleanupError {
            await session.printFailureDiagnostics()
            throw AndroidRuntimeFailure(
                "\(runtimeError); \(cleanupError)")
        }
        await session.printFailureDiagnostics()
        throw runtimeError
    }
}

private func recordRuntimeBridgeEvent<
    RuntimeHost: AndroidRuntimeHost
>(
    _ event: AndroidRuntimeBridgeEvent,
    session: AndroidRuntimeSession<RuntimeHost>
) async {
    switch event {
    case .connected(let generation):
        try? await session.recordRuntimeBridgeStage(
            "connected",
            fields: ["generation": generation])
    case .inputReady(let generation):
        try? await session.recordRuntimeBridgeStage(
            "input-ready",
            fields: ["generation": generation])
    case .inputFailed(let generation, let error):
        try? await session.recordRuntimeBridgeStage(
            "input-failed",
            fields: [
                "generation": generation,
                "error": error,
            ])
    case .userUnlocked(let generation, let userSerial):
        try? await session.recordRuntimeBridgeStage(
            "user-unlocked",
            fields: [
                "generation": generation,
                "userSerial": String(userSerial),
            ])
    case .activitiesReplaced(
        let generation,
        let userSerial,
        let activities
    ):
        try? await session.recordRuntimeBridgeStage(
            "activities-replaced",
            fields: [
                "generation": generation,
                "userSerial": String(userSerial),
                "count": String(activities.count),
            ])
    case .cursorShapeChanged(let generation, let update):
        try? await session.recordRuntimeBridgeStage(
            "cursor-shape-changed",
            fields: [
                "generation": generation,
                "displayId": String(update.displayID),
                "pointerIconType": String(update.pointerIconType),
            ])
    case .disconnected(let generation):
        try? await session.recordRuntimeBridgeStage(
            "disconnected",
            fields: ["generation": generation])
    }
}
