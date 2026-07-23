import Foundation
import Glibc
import NucleusSessionProtocol

struct AndroidPresentationQualificationOptions: Equatable {
    var drmDevice: String
    var frames: Int
    var output: String?
    var scale: Double
    var presentMode: String
    var build: Bool
    var validation: Bool
    var diagnostics: Bool
}

struct DrmPresentationPreflightRecord: Codable, Equatable {
    var renderDevice: String
    var connectedConnectors: [String]
}

struct DrmPresentationPreflight {
    static func connectedConnectors(
        renderDevice: String,
        sysfsRoot: URL = URL(fileURLWithPath: "/sys/class/drm")
    ) throws -> [String] {
        let renderName = URL(fileURLWithPath: renderDevice).lastPathComponent
        guard renderDevice.hasPrefix("/dev/dri/renderD"),
              !renderName.dropFirst("renderD".count).isEmpty,
              renderName.dropFirst("renderD".count).allSatisfy(\.isNumber)
        else {
            throw WorkspaceFailure.message(
                "--drm-device must name an absolute DRM render node under /dev/dri")
        }

        let deviceDrm = sysfsRoot
            .appendingPathComponent(renderName)
            .appendingPathComponent("device/drm")
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                atPath: deviceDrm.path)
        } catch {
            throw WorkspaceFailure.message(
                "cannot inspect the KMS device paired with \(renderDevice): \(error)")
        }
        let cards = entries.filter { value in
            value.hasPrefix("card")
                && !value.dropFirst("card".count).isEmpty
                && value.dropFirst("card".count).allSatisfy(\.isNumber)
        }
        guard !cards.isEmpty else {
            throw WorkspaceFailure.message(
                "no KMS primary node is paired with \(renderDevice)")
        }

        var connected: [String] = []
        for card in cards {
            let connectors = (try? FileManager.default.contentsOfDirectory(
                atPath: sysfsRoot.path)) ?? []
            for connector in connectors
            where connector.hasPrefix(card + "-")
            {
                let connectorRoot = sysfsRoot.appendingPathComponent(connector)
                let status = try? String(
                    contentsOf: connectorRoot.appendingPathComponent("status"),
                    encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let modes = try? String(
                    contentsOf: connectorRoot.appendingPathComponent("modes"),
                    encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if status == "connected", let modes, !modes.isEmpty {
                    connected.append(connector)
                }
            }
        }
        return connected.sorted()
    }
}

struct AndroidPresentationQualificationCommand {
    let context: WorkspaceContext

    func run(_ options: AndroidPresentationQualificationOptions) throws {
        try requireFreeSeat()
        let connected = try DrmPresentationPreflight.connectedConnectors(
            renderDevice: options.drmDevice)
        guard !connected.isEmpty else {
            throw WorkspaceFailure.message(
                "\(options.drmDevice) has no connected display with a usable mode; "
                    + "connect the monitor to that GPU before running live qualification")
        }

        let runtimeOptions = RuntimeBuildOptions()
        let installation: RuntimeInstallation
        if options.build {
            try ComponentRegistry(context: context).build(
                selection: "android-runtime",
                dryRun: false,
                explain: false,
                verbose: false,
                json: false)
            installation = try RuntimeInstaller(context: context).install(
                .session,
                prefix: context.root.appendingPathComponent(".install"),
                options: runtimeOptions)
        } else {
            installation = try RuntimeInstaller(context: context).existingSession(
                prefix: context.root.appendingPathComponent(".install"),
                options: runtimeOptions)
        }
        let products = try androidProducts()
        let output = try createOutputDirectory(options.output)
        let supportBundle = output
            .deletingLastPathComponent()
            .appendingPathComponent(output.lastPathComponent + ".tar.gz")
        let runtime = try createSessionRuntimeDirectory()
        defer { try? FileManager.default.removeItem(at: runtime.directory) }

        let preflight = DrmPresentationPreflightRecord(
            renderDevice: options.drmDevice,
            connectedConnectors: connected)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preflight).write(
            to: output.appendingPathComponent("drm-preflight.json"),
            options: .atomic)
        try FileManager.default.copyItem(
            at: context.root.appendingPathComponent(
                "android-runtime/gfxstream.lock.json"),
            to: output.appendingPathComponent("gfxstream.lock.json"))

        let sessionStatus = output.appendingPathComponent("session-status.bin")
        let sessionLog = output.appendingPathComponent("session.log")
        var sessionEnvironment = context.environment
        if options.validation {
            let layer = try VulkanValidationLayer.resolve(
                environment: sessionEnvironment)
            layer.applying(to: &sessionEnvironment)
        }
        sessionEnvironment["XDG_RUNTIME_DIR"] = runtime.parent.path
        sessionEnvironment["NUCLEUS_SESSION_ID"] = runtime.identifier
        sessionEnvironment["NUCLEUS_SESSION_RUNTIME_DIR"] = runtime.directory.path
        sessionEnvironment["NUCLEUS_EPHEMERAL_CONFIG"] = "1"
        sessionEnvironment["NUCLEUS_RUN_LOG"] = sessionLog.path

        let configuration = try SessionConfiguration(
            outputScale: options.scale,
            presentMode: options.presentMode == "mailbox_latest_wins"
                ? .mailboxLatestWins : .vsync,
            enableVulkanValidation: options.validation,
            traceProtocol: options.diagnostics,
            traceDrmDemand: options.diagnostics,
            drmDevicePath: options.drmDevice)
        let session = context.start(
            installation.session.path,
            [
                "--status-file", sessionStatus.path,
                "--configuration", configuration.hexEncoded,
                "--", installation.compositor.path,
            ],
            environmentOverrides: sessionEnvironment)

        var sessionStopped = false
        func stopSession() {
            guard !sessionStopped else { return }
            sessionStopped = true
            session.cancel()
            _ = try? session.wait()
        }
        defer { stopSession() }

        var workflowFailure: (any Error)?
        var qualificationStatus: Int32?
        do {
            try waitForSessionReadiness(
                session: session,
                statusFile: sessionStatus)
            let qualification = context.start(
                products.qualifier.path,
                [
                    "--broker", products.broker.path,
                    "--workload", products.workload.path,
                    "--expected-render-device", options.drmDevice,
                    "--wayland", "wayland-0",
                    "--output", output.path,
                    "--support-bundle", supportBundle.path,
                    "--frames", String(options.frames),
                ],
                environmentOverrides: [
                    "XDG_RUNTIME_DIR": runtime.directory.path,
                    "NUCLEUS_SESSION_RUNTIME_DIR": runtime.directory.path,
                    "NUCLEUS_SESSION_ID": runtime.identifier,
                ])
            qualificationStatus = try qualification.wait().status
        } catch {
            workflowFailure = error
        }

        stopSession()
        do {
            try context.run(
                "tar",
                [
                    "-C", output.deletingLastPathComponent().path,
                    "-czf", supportBundle.path,
                    output.lastPathComponent,
                ])
        } catch {
            if workflowFailure == nil { workflowFailure = error }
        }
        print("qualification support bundle: \(supportBundle.path)")

        if let workflowFailure { throw workflowFailure }
        guard qualificationStatus == 0 else {
            throw WorkspaceFailure.message(
                "Android presentation qualification was rejected; inspect "
                    + output.appendingPathComponent("summary.json").path)
        }
    }

    private func requireFreeSeat() throws {
        if context.environment["WAYLAND_DISPLAY"] != nil
            || context.environment["DISPLAY"] != nil
        {
            throw WorkspaceFailure.message(
                "cannot launch live presentation qualification inside an existing "
                    + "Wayland/X11 desktop session; switch to a free virtual terminal")
        }
    }

    private func androidProducts() throws -> (
        qualifier: URL,
        broker: URL,
        workload: URL
    ) {
        let package = context.root.appendingPathComponent("android-runtime")
        let raw = try context.run(
            "swift",
            [
                "build",
                "--package-path", package.path,
                "--show-bin-path",
            ],
            capture: true)
        let directory = URL(fileURLWithPath: raw)
        let products = (
            qualifier: directory.appendingPathComponent(
                "nucleus-android-presentation-qualifier"),
            broker: directory.appendingPathComponent(
                "nucleus-android-gpu-broker"),
            workload: directory.appendingPathComponent(
                "nucleus-android-gfxstream-workload")
        )
        for executable in [
            products.qualifier,
            products.broker,
            products.workload,
        ] where !FileManager.default.isExecutableFile(atPath: executable.path) {
            throw WorkspaceFailure.message(
                "Android presentation product is not built: \(executable.path)")
        }
        return products
    }

    private func createOutputDirectory(_ supplied: String?) throws -> URL {
        let output: URL
        if let supplied {
            output = URL(
                fileURLWithPath: supplied,
                relativeTo: context.root).standardizedFileURL
        } else {
            let timestamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            output = context.root
                .appendingPathComponent(
                    ".nucleus/qualifications/android-presentation")
                .appendingPathComponent(
                    "\(timestamp)-\(UUID().uuidString.lowercased())")
        }
        guard !FileManager.default.fileExists(atPath: output.path),
              !FileManager.default.fileExists(
                atPath: output.path + ".tar.gz")
        else {
            throw WorkspaceFailure.message(
                "qualification output already exists: \(output.path)")
        }
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true)
        return output
    }

    private func createSessionRuntimeDirectory() throws -> (
        identifier: String,
        parent: URL,
        directory: URL
    ) {
        let parentPath = context.environment["XDG_RUNTIME_DIR"]
            ?? "/run/user/\(getuid())"
        let parent = URL(fileURLWithPath: parentPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard parent.path != "/",
              FileManager.default.fileExists(
                atPath: parent.path,
                isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WorkspaceFailure.message(
                "the login runtime directory does not exist: \(parent.path)")
        }
        let identifier =
            "android-presentation-\(UUID().uuidString.lowercased())"
        let directory = parent.appendingPathComponent("nucleus-\(identifier)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return (identifier, parent, directory)
    }

    private func waitForSessionReadiness(
        session: WorkspaceManagedCommand,
        statusFile: URL
    ) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: statusFile),
               let message = SessionReadinessMessage(encoded: Array(data))
            {
                if message.role == .shell,
                   message.milestone == .shellReady
                {
                    return
                }
                if message.milestone == .failed {
                    let reason = SessionFailureReason(rawValue: message.detail)
                    throw WorkspaceFailure.message(
                        "Nucleus session startup failed: "
                            + (reason.map(String.init(describing:))
                                ?? "reason \(message.detail)"))
                }
            }
            guard session.isRunning else {
                throw WorkspaceFailure.message(
                    "Nucleus session exited before becoming ready "
                        + "(status \(session.terminationStatus ?? -1))")
            }
            usleep(20_000)
        }
        throw WorkspaceFailure.message(
            "Nucleus session did not become ready before the startup deadline")
    }
}
