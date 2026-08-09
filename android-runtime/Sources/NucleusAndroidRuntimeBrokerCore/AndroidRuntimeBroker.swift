import Foundation
import Glibc
internal import NucleusAndroidRuntimeBridgeProtocol
import NucleusAndroidRuntimeCore
import NucleusSessionProtocol

package struct AndroidRuntimeBrokerConfiguration: Sendable {
    package let addonRoot: URL
    package let persistentStateRoot: URL
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
        addonRoot: URL,
        persistentStateRoot: URL,
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
            addonRoot,
            persistentStateRoot,
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
        self.addonRoot = addonRoot
        self.persistentStateRoot = persistentStateRoot
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
    let layout = try AndroidRuntimeLayout(
        addonRoot: configuration.addonRoot,
        persistentStateRoot: configuration.persistentStateRoot,
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
        layout.addonManifest,
        layout.provenance,
        layout.avbTool,
        layout.verificationKey,
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
        let applicationProvider = try ApplicationProviderPublicationServer(
            providerID: "android",
            sessionRuntimeDirectory: configuration.sessionRuntimeDirectory,
            expectedUserID: getuid())
        let applicationCatalog = try AndroidApplicationCatalogPublisher(
            server: applicationProvider,
            sessionRuntimeDirectory: configuration.sessionRuntimeDirectory)
        try await session.recordRuntimeBridgeListener()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await bridge.run { event in
                    if case .cursorShapeChanged(_, let update) = event {
                        try? displayInteraction.send(update)
                    }
                    try? await applicationCatalog.handle(event)
                    await recordRuntimeBridgeEvent(
                        event,
                        session: session)
                }
            }
            group.addTask {
                try await applicationProvider.run()
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

actor AndroidApplicationCatalogPublisher {
    private struct ActivityKey: Hashable {
        var packageName: String
        var activityName: String
    }

    private let server: ApplicationProviderPublicationServer
    private let iconDirectory: URL
    private var activities: [ActivityKey: AndroidRuntimeBridgeActivity] = [:]
    private var userSerial: Int64?

    init(
        server: ApplicationProviderPublicationServer,
        sessionRuntimeDirectory: URL
    ) throws {
        self.server = server
        iconDirectory =
            sessionRuntimeDirectory
            .appendingPathComponent("application-provider-assets", isDirectory: true)
            .appendingPathComponent("android", isDirectory: true)
        try FileManager.default.createDirectory(
            at: iconDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard unsafe chmod(iconDirectory.path, 0o700) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    func handle(_ event: AndroidRuntimeBridgeEvent) throws {
        switch event {
        case .iconAsset(_, _, let asset):
            try store(asset)
        case .activitiesReplaced(_, let serial, let replacement):
            userSerial = serial
            activities = Dictionary(
                uniqueKeysWithValues: replacement.map { (key(for: $0), $0) })
            let replacementRecords = try records()
            try? server.publish(.replace(replacementRecords))
            garbageCollectIcons()
        case .packageActivitiesReplaced(
            _, let serial, let packageName, let replacement
        ):
            guard userSerial == serial else { return }
            let oldKeys = Set(
                activities.keys.filter {
                    $0.packageName == packageName
                })
            let replacementByKey = Dictionary(
                uniqueKeysWithValues: replacement.map { (key(for: $0), $0) })
            let newKeys = Set(replacementByKey.keys)
            for removed in oldKeys.subtracting(newKeys) {
                activities.removeValue(forKey: removed)
                try? server.publish(.remove(applicationID(for: removed, serial: serial)))
            }
            for key in newKeys.sorted(by: keyOrdering) {
                guard let activity = replacementByKey[key] else { continue }
                activities[key] = activity
                let replacementRecord = try record(for: activity, serial: serial)
                try? server.publish(.upsert(replacementRecord))
            }
            garbageCollectIcons()
        case .userLocked, .disconnected:
            userSerial = nil
            activities.removeAll(keepingCapacity: true)
            try? server.publish(.replace([]))
            garbageCollectIcons()
        case .connected, .inputReady, .inputFailed, .userUnlocked,
            .cursorShapeChanged:
            break
        }
    }

    private func records() throws -> [ApplicationProviderRecord] {
        guard let userSerial else { return [] }
        return try activities.values
            .sorted { keyOrdering(key(for: $0), key(for: $1)) }
            .map { try record(for: $0, serial: userSerial) }
    }

    private func record(
        for activity: AndroidRuntimeBridgeActivity,
        serial: Int64
    ) throws -> ApplicationProviderRecord {
        let key = key(for: activity)
        let localID = localID(for: key, serial: serial)
        let icon: ApplicationProviderIcon?
        if let digest = activity.iconDigest {
            let path = iconURL(for: digest)
            icon =
                FileManager.default.fileExists(atPath: path.path)
                ? .rasterAsset(digest: digest, path: path.path)
                : nil
        } else {
            icon = nil
        }
        return try ApplicationProviderRecord(
            id: "android:\(localID)",
            name: activity.label,
            icon: icon,
            categories: activity.categories ?? [],
            launchID: localID)
    }

    private func store(_ asset: AndroidRuntimeBridgeIconAsset) throws {
        // The fixed-UID, platform-signed bridge is the content-address producer.
        // The host bounds and validates its PNG packet before using this digest
        // as a filename; no untrusted peer can publish on this channel.
        let destination = iconURL(for: asset.digest)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return
        }
        try asset.bytes.write(to: destination, options: .atomic)
        guard unsafe chmod(destination.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func garbageCollectIcons() {
        let referenced = Set(activities.values.compactMap(\.iconDigest))
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: iconDirectory,
                includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "png" {
            let digest = file.deletingPathExtension().lastPathComponent
            if !referenced.contains(digest) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func iconURL(for digest: String) -> URL {
        iconDirectory.appendingPathComponent("\(digest).png")
    }

    private func key(for activity: AndroidRuntimeBridgeActivity) -> ActivityKey {
        ActivityKey(
            packageName: activity.packageName,
            activityName: activity.activityName)
    }

    private func localID(for key: ActivityKey, serial: Int64) -> String {
        "\(serial):\(key.packageName)/\(key.activityName)"
    }

    private func applicationID(for key: ActivityKey, serial: Int64) -> String {
        "android:\(localID(for: key, serial: serial))"
    }

    private func keyOrdering(_ lhs: ActivityKey, _ rhs: ActivityKey) -> Bool {
        lhs.packageName == rhs.packageName
            ? lhs.activityName < rhs.activityName
            : lhs.packageName < rhs.packageName
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
    case .userLocked(let generation, let userSerial):
        try? await session.recordRuntimeBridgeStage(
            "user-locked",
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
    case .packageActivitiesReplaced(
        let generation,
        let userSerial,
        let packageName,
        let activities
    ):
        try? await session.recordRuntimeBridgeStage(
            "package-activities-replaced",
            fields: [
                "generation": generation,
                "userSerial": String(userSerial),
                "packageName": packageName,
                "count": String(activities.count),
            ])
    case .iconAsset(let generation, let userSerial, let asset):
        try? await session.recordRuntimeBridgeStage(
            "icon-asset",
            fields: [
                "generation": generation,
                "userSerial": String(userSerial),
                "digest": asset.digest,
                "bytes": String(asset.bytes.count),
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
