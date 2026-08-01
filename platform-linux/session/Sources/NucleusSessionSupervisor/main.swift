import Foundation
import Glibc
import NucleusDiagnostics
import NucleusLinuxSessionC
import NucleusSessionProtocol

private enum SupervisorFailure: Error, CustomStringConvertible {
    case usage(String)
    case system(String, Int32)
    case channel(String)
    case childExited(SessionProcessRole, Int32)
    case readinessClosed(SessionProcessRole)
    case invalidReadiness(SessionProcessRole)
    case startupTimedOut(SessionProcessRole)
    case interrupted(Int32)

    var description: String {
        switch self {
        case .usage(let message): message
        case .system(let operation, let error):
            "\(operation) failed: errno \(error)"
        case .channel(let message):
            "session channel failed: \(message)"
        case .childExited(let role, let status):
            "\(role) exited before the session became ready (status \(status))"
        case .readinessClosed(let role):
            "\(role) closed its readiness channel without reporting readiness"
        case .invalidReadiness(let role):
            "\(role) sent an invalid readiness record"
        case .startupTimedOut(let role):
            "\(role) did not become ready before the startup deadline"
        case .interrupted(let signal):
            "session received signal \(signal)"
        }
    }
}

private struct SupervisorArguments {
    var statusFile: String?
    var configuration: SessionConfiguration
    var configService: String
    var controlService: String
    var shell: String
    var compositor: [String]
    var capabilities: [SessionCapabilityDeclaration]
    var startupTimeoutMilliseconds: Int32 = 30_000

    static func parse(_ arguments: [String]) throws -> SupervisorArguments {
        var statusFile: String?
        var configuration = SessionConfiguration.defaults
        var configService: String?
        var controlService: String?
        var shell: String?
        var capabilities: [SessionCapabilityDeclaration] = []
        var startupTimeoutMilliseconds: Int32 = 30_000
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--status-file":
                guard index + 1 < arguments.count else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                index += 1
                statusFile = arguments[index]
            case "--shell":
                guard index + 1 < arguments.count else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                index += 1
                shell = arguments[index]
            case "--config-service":
                guard index + 1 < arguments.count else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                index += 1
                configService = arguments[index]
            case "--control-service":
                guard index + 1 < arguments.count else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                index += 1
                controlService = arguments[index]
            case "--configuration":
                guard index + 1 < arguments.count else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                index += 1
                do {
                    configuration = try SessionConfiguration(
                        hexEncoded: arguments[index])
                } catch {
                    throw SupervisorFailure.usage(
                        "invalid session configuration: \(error)")
                }
            case "--capability-manifest":
                guard index + 1 < arguments.count else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                index += 1
                do {
                    let data = try Data(
                        contentsOf: URL(fileURLWithPath: arguments[index]))
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    capabilities.append(
                        try decoder.decode(
                            SessionCapabilityDeclaration.self,
                            from: data))
                } catch {
                    throw SupervisorFailure.usage(
                        "invalid session capability manifest "
                            + "\(arguments[index]): \(error)")
                }
            case "--startup-timeout-seconds":
                guard index + 1 < arguments.count,
                    let seconds = Int32(arguments[index + 1]),
                    seconds > 0,
                    seconds <= 600
                else {
                    throw SupervisorFailure.usage(
                        "--startup-timeout-seconds must be between 1 and 600")
                }
                index += 1
                startupTimeoutMilliseconds = seconds * 1_000
            case "--":
                let compositor = Array(arguments.dropFirst(index + 1))
                guard let configService, !configService.isEmpty,
                    let controlService, !controlService.isEmpty,
                    let shell, !shell.isEmpty, !compositor.isEmpty,
                    Set(capabilities.map(\.identifier)).count
                        == capabilities.count
                else {
                    throw SupervisorFailure.usage(Self.usage)
                }
                return SupervisorArguments(
                    statusFile: statusFile,
                    configuration: configuration,
                    configService: configService,
                    controlService: controlService,
                    shell: shell,
                    compositor: compositor,
                    capabilities: capabilities,
                    startupTimeoutMilliseconds: startupTimeoutMilliseconds)
            case "-h", "--help":
                throw SupervisorFailure.usage(Self.usage)
            default:
                throw SupervisorFailure.usage(Self.usage)
            }
            index += 1
        }
        throw SupervisorFailure.usage(Self.usage)
    }

    static let usage = """
        usage: nucleus-session-supervisor [--status-file PATH] [--configuration HEX] [--startup-timeout-seconds N] [--capability-manifest PATH]... --config-service PATH --control-service PATH --shell PATH -- COMMAND [ARGS...]
        """
}

private struct SupervisedChild {
    let role: SessionProcessRole
    let processID: pid_t
    let readinessDescriptor: Int32
}

private struct UnexpectedSessionExit {
    let role: SessionProcessRole
    let status: Int32
}

private struct SupervisedCapability {
    let declaration: SessionCapabilityDeclaration
    let processID: pid_t
    let restartCount: UInt8
}

private enum UnexpectedProcessExit {
    case session(UnexpectedSessionExit)
    case capability(identifier: String, status: Int32)
}

private struct SessionStatusPublisher {
    let path: String?

    func publish(_ message: SessionReadinessMessage) throws {
        guard let path else { return }
        try Data(message.encoded).write(
            to: URL(fileURLWithPath: path),
            options: .atomic)
    }
}

private final class SupervisorSessionRuntime {
    private let ownedDirectory: String?

    private init(ownedDirectory: String?) {
        self.ownedDirectory = ownedDirectory
    }

    static func prepare() throws -> SupervisorSessionRuntime {
        let environment = ProcessInfo.processInfo.environment
        if let supplied = environment["NUCLEUS_SESSION_RUNTIME_DIR"] {
            guard environment["XDG_RUNTIME_DIR"] == supplied else {
                throw SupervisorFailure.usage(
                    "NUCLEUS_SESSION_RUNTIME_DIR must equal XDG_RUNTIME_DIR")
            }
            return SupervisorSessionRuntime(ownedDirectory: nil)
        }

        guard let parent = environment["XDG_RUNTIME_DIR"],
            parent.hasPrefix("/"), !parent.isEmpty
        else {
            throw SupervisorFailure.usage(
                "XDG_RUNTIME_DIR is required")
        }
        let sessionID =
            environment["NUCLEUS_SESSION_ID"]
            ?? String(getpid())
        guard !sessionID.isEmpty, !sessionID.contains("/") else {
            throw SupervisorFailure.usage(
                "NUCLEUS_SESSION_ID must not contain '/'")
        }
        let directory = parent + "/nucleus-" + sessionID
        guard unsafe mkdir(directory, 0o700) == 0 else {
            throw SupervisorFailure.system(
                "creating the session runtime directory", errno)
        }
        guard unsafe setenv("XDG_RUNTIME_DIR", directory, 1) == 0,
            unsafe setenv(
                "NUCLEUS_SESSION_RUNTIME_DIR", directory, 1) == 0,
            unsafe setenv("NUCLEUS_SESSION_ID", sessionID, 1) == 0
        else {
            try? FileManager.default.removeItem(atPath: directory)
            throw SupervisorFailure.system(
                "exporting the session runtime directory", errno)
        }
        return SupervisorSessionRuntime(ownedDirectory: directory)
    }

    func removeOwnedDirectory() {
        guard let ownedDirectory else { return }
        try? FileManager.default.removeItem(atPath: ownedDirectory)
    }
}

private final class SessionSupervisor {
    private static let childReadinessDescriptor: Int32 = 198
    private static let childConfigurationDescriptor: Int32 = 197
    private static let childConfigServiceDescriptor: Int32 = 196
    private static let serviceRenderServerDescriptor: Int32 = 196
    private static let serviceShellDescriptor: Int32 = 195
    private static let serviceControlDescriptor: Int32 = 194
    private static let controlServiceConfigDescriptor: Int32 = 196
    private static let controlServiceRenderDescriptor: Int32 = 195
    private static let controlServiceElevatedDescriptor: Int32 = 194
    private static let renderServerControlDescriptor: Int32 = 195
    private static let shellControlCapabilityDescriptor: Int32 = 195
    private static let serviceAttachmentDescriptor: Int32 = 193
    private static let compositorShellPolicyAttachmentDescriptor: Int32 = 193
    private static let shellPolicyDescriptor: Int32 = 193

    private let arguments: SupervisorArguments
    private let statusPublisher: SessionStatusPublisher
    private let signalDescriptor: Int32
    private var controlSocketPath: String?

    init(arguments: SupervisorArguments) throws {
        self.arguments = arguments
        statusPublisher = SessionStatusPublisher(path: arguments.statusFile)

        let descriptor = nucleus_session_create_signal_fd()
        guard descriptor >= 0 else {
            throw SupervisorFailure.system("signalfd", errno)
        }
        signalDescriptor = descriptor
    }

    deinit { _ = close(signalDescriptor) }

    func run() -> Int32 {
        var children: [SupervisedChild] = []
        var capabilities: [SupervisedCapability] = []
        do {
            let sessionRuntime = try SupervisorSessionRuntime.prepare()
            defer { sessionRuntime.removeOwnedDirectory() }
            if unsafe getenv("WAYLAND_DISPLAY") == nil {
                guard unsafe setenv("WAYLAND_DISPLAY", "wayland-0", 1) == 0
                else {
                    throw SupervisorFailure.system(
                        "selecting the session Wayland socket", errno)
                }
            }
            let renderConfigurationPair = try SessionChannel.socketPair()
            let shellConfigurationPair = try SessionChannel.socketPair()
            let controlConfigurationPair = try SessionChannel.socketPair()
            let renderControlPair = try SessionChannel.socketPair()
            let elevatedPair = try SessionChannel.socketPair()
            let configAttachmentPair = try SessionChannel.socketPair()
            let controlAttachmentPair = try SessionChannel.socketPair()
            let shellPolicyAttachmentPair = try SessionChannel.socketPair()
            let elevatedAuthority = dup(elevatedPair.0)
            let shellElevatedCapability = dup(elevatedPair.0)
            guard elevatedAuthority >= 0, shellElevatedCapability >= 0 else {
                throw SupervisorFailure.system(
                    "duplicating elevated control capability", errno)
            }
            defer { _ = close(elevatedAuthority) }
            _ = close(elevatedPair.1)
            var configAttachments = SupervisorAttachmentChannel(
                owning: configAttachmentPair.1)
            let controlAttachments = SupervisorAttachmentChannel(
                owning: controlAttachmentPair.1)
            var shellPolicyAttachments = ShellPolicyAttachmentChannel(
                owning: shellPolicyAttachmentPair.1)
            var configService = try spawn(
                role: .configService,
                command: [arguments.configService],
                inheritedDescriptors: [
                    InheritedDescriptor(
                        source: renderConfigurationPair.0,
                        target: Self.serviceRenderServerDescriptor,
                        argument: "--nucleus-render-server-config-fd"),
                    InheritedDescriptor(
                        source: shellConfigurationPair.0,
                        target: Self.serviceShellDescriptor,
                        argument: "--nucleus-shell-config-fd"),
                    InheritedDescriptor(
                        source: controlConfigurationPair.0,
                        target: Self.serviceControlDescriptor,
                        argument: "--nucleus-control-config-fd"),
                    InheritedDescriptor(
                        source: configAttachmentPair.0,
                        target: Self.serviceAttachmentDescriptor,
                        argument:
                            SupervisorAttachmentChannel.descriptorArgument),
                ],
                sendsSessionConfiguration: false)
            children.append(configService)
            let configReady = try waitForReadiness(
                configService,
                milestone: .configServiceReady,
                monitoring: children)
            try statusPublisher.publish(configReady)
            log("configuration service ready pid=\(configService.processID)")

            let socketDirectory = try createControlSocketDirectory()
            controlSocketPath = socketDirectory + "/control.sock"
            let controlService = try spawn(
                role: .controlService,
                command: [
                    arguments.controlService,
                    "--nucleus-control-socket-directory",
                    socketDirectory,
                ],
                inheritedDescriptors: [
                    InheritedDescriptor(
                        source: controlConfigurationPair.1,
                        target: Self.controlServiceConfigDescriptor,
                        argument: "--nucleus-control-config-fd"),
                    InheritedDescriptor(
                        source: renderControlPair.0,
                        target: Self.controlServiceRenderDescriptor,
                        argument:
                            RenderServerControlChannel.descriptorArgument),
                    InheritedDescriptor(
                        source: elevatedPair.0,
                        target: Self.controlServiceElevatedDescriptor,
                        argument: "--nucleus-control-elevated-fd"),
                    InheritedDescriptor(
                        source: controlAttachmentPair.0,
                        target: Self.serviceAttachmentDescriptor,
                        argument:
                            SupervisorAttachmentChannel.descriptorArgument),
                ],
                sendsSessionConfiguration: false)
            children.append(controlService)
            let controlReady = try waitForReadiness(
                controlService,
                milestone: .controlServiceReady,
                monitoring: children)
            try statusPublisher.publish(controlReady)
            log("control service ready pid=\(controlService.processID)")

            var compositor = try spawn(
                role: .compositor,
                command: arguments.compositor,
                inheritedDescriptors: [
                    InheritedDescriptor(
                        source: renderConfigurationPair.1,
                        target: Self.childConfigServiceDescriptor,
                        argument:
                            ConfigurationClientChannel.descriptorArgument),
                    InheritedDescriptor(
                        source: renderControlPair.1,
                        target: Self.renderServerControlDescriptor,
                        argument:
                            RenderServerControlChannel.descriptorArgument),
                    InheritedDescriptor(
                        source: shellPolicyAttachmentPair.0,
                        target:
                            Self.compositorShellPolicyAttachmentDescriptor,
                        argument:
                            ShellPolicyAttachmentChannel
                            .descriptorArgument),
                ])
            children.append(compositor)
            let compositorReady = try waitForReadiness(
                compositor,
                milestone: .compositorReady,
                monitoring: children)
            try statusPublisher.publish(compositorReady)
            log("compositor ready pid=\(compositor.processID)")

            var shell = try spawnShell(
                configurationDescriptor: shellConfigurationPair.1,
                elevatedDescriptor: shellElevatedCapability,
                attachments: shellPolicyAttachments)
            children.append(shell)
            let shellReady = try waitForReadiness(
                shell,
                milestone: .shellReady,
                monitoring: children)
            try statusPublisher.publish(shellReady)
            log("shell ready pid=\(shell.processID)")
            for declaration in arguments.capabilities {
                do {
                    capabilities.append(
                        try spawnCapability(
                            declaration,
                            restartCount: 0))
                } catch {
                    log(
                        "capability \(declaration.identifier) failed to "
                            + "start: \(error)")
                }
            }

            while true {
                children = [configService, controlService, compositor, shell]
                let processExit = try waitForSessionExit(
                    children,
                    capabilities: capabilities)
                if case .capability(let identifier, let status) = processExit {
                    guard
                        let index = capabilities.firstIndex(where: {
                            $0.declaration.identifier == identifier
                        })
                    else {
                        throw SupervisorFailure.channel(
                            "unknown capability process exited: \(identifier)")
                    }
                    let exited = capabilities.remove(at: index)
                    let shouldRestart =
                        exited.restartCount
                        < exited.declaration.maximumRestarts
                        && (exited.declaration.restartPolicy == .always
                            || exited.declaration.restartPolicy == .onFailure
                                && status != 0)
                    if shouldRestart {
                        do {
                            capabilities.append(
                                try spawnCapability(
                                    exited.declaration,
                                    restartCount: exited.restartCount + 1))
                        } catch {
                            log(
                                "capability \(identifier) failed to restart: "
                                    + "\(error)")
                        }
                    } else {
                        log(
                            "capability \(identifier) exited status=\(status) "
                                + "restarts=\(exited.restartCount)")
                    }
                    continue
                }
                guard case .session(let unexpectedExit) = processExit else {
                    throw SupervisorFailure.channel(
                        "invalid supervised process exit")
                }
                switch unexpectedExit.role {
                case .controlService:
                    try statusPublisher.publish(
                        SessionReadinessMessage(
                            role: .supervisor,
                            milestone: .failed,
                            detail: SessionFailureReason
                                .controlServiceExitedAfterReady.rawValue))
                    revokePublicControlAccess()
                    terminateCapabilities(capabilities)
                    capabilities.removeAll()
                    terminate([configService, compositor, shell])
                    return unexpectedExit.status == 0
                        ? 1 : unexpectedExit.status
                case .compositor:
                    log("render server exited; replacing owner")
                    // Replace the shell generation so its policy and
                    // configuration channels belong to the new render-server
                    // generation. Its Wayland connection is ordinary.
                    terminate([shell])
                    children = [configService, controlService]
                    let configPair = try SessionChannel.socketPair()
                    try configAttachments.send(
                        role: .renderServerConfigurationSubscriber,
                        descriptor: configPair.0)
                    _ = close(configPair.0)
                    let shellConfigPair = try SessionChannel.socketPair()
                    try configAttachments.send(
                        role: .shellConfigurationSubscriber,
                        descriptor: shellConfigPair.0)
                    _ = close(shellConfigPair.0)
                    let controlPair = try SessionChannel.socketPair()
                    try controlAttachments.send(
                        role: .renderServerControl,
                        descriptor: controlPair.0)
                    _ = close(controlPair.0)
                    let attachmentPair = try SessionChannel.socketPair()
                    shellPolicyAttachments = ShellPolicyAttachmentChannel(
                        owning: attachmentPair.1)
                    compositor = try spawn(
                        role: .compositor,
                        command: arguments.compositor,
                        inheritedDescriptors: [
                            InheritedDescriptor(
                                source: configPair.1,
                                target: Self.childConfigServiceDescriptor,
                                argument:
                                    ConfigurationClientChannel
                                    .descriptorArgument),
                            InheritedDescriptor(
                                source: controlPair.1,
                                target: Self.renderServerControlDescriptor,
                                argument:
                                    RenderServerControlChannel
                                    .descriptorArgument),
                            InheritedDescriptor(
                                source: attachmentPair.0,
                                target:
                                    Self.compositorShellPolicyAttachmentDescriptor,
                                argument:
                                    ShellPolicyAttachmentChannel
                                    .descriptorArgument),
                        ])
                    children = [configService, controlService, compositor]
                    let ready = try waitForReadiness(
                        compositor,
                        milestone: .compositorReady,
                        monitoring: children)
                    try statusPublisher.publish(ready)
                    let capability = dup(elevatedAuthority)
                    guard capability >= 0 else {
                        throw SupervisorFailure.system(
                            "duplicating shell control capability", errno)
                    }
                    shell = try spawnShell(
                        configurationDescriptor: shellConfigPair.1,
                        elevatedDescriptor: capability,
                        attachments: shellPolicyAttachments)
                    children = [
                        configService, controlService, compositor, shell,
                    ]
                    let shellReady = try waitForReadiness(
                        shell,
                        milestone: .shellReady,
                        monitoring: children)
                    try statusPublisher.publish(shellReady)
                case .shell:
                    log("shell exited; replacing shell process")
                    let configPair = try SessionChannel.socketPair()
                    try configAttachments.send(
                        role: .shellConfigurationSubscriber,
                        descriptor: configPair.0)
                    _ = close(configPair.0)
                    let capability = dup(elevatedAuthority)
                    guard capability >= 0 else {
                        throw SupervisorFailure.system(
                            "duplicating shell control capability", errno)
                    }
                    shell = try spawnShell(
                        configurationDescriptor: configPair.1,
                        elevatedDescriptor: capability,
                        attachments: shellPolicyAttachments)
                    children = [
                        configService, controlService, compositor, shell,
                    ]
                    let ready = try waitForReadiness(
                        shell,
                        milestone: .shellReady,
                        monitoring: [
                            configService, controlService, compositor, shell,
                        ])
                    try statusPublisher.publish(ready)
                case .configService:
                    log(
                        "configuration service exited; replacing dependent "
                            + "owners")
                    terminate([compositor, shell])
                    children = [controlService]
                    let renderConfigPair = try SessionChannel.socketPair()
                    let shellConfigPair = try SessionChannel.socketPair()
                    let controlConfigPair = try SessionChannel.socketPair()
                    let newAttachmentPair = try SessionChannel.socketPair()
                    configAttachments = SupervisorAttachmentChannel(
                        owning: newAttachmentPair.1)
                    configService = try spawn(
                        role: .configService,
                        command: [arguments.configService],
                        inheritedDescriptors: [
                            InheritedDescriptor(
                                source: renderConfigPair.0,
                                target:
                                    Self.serviceRenderServerDescriptor,
                                argument:
                                    "--nucleus-render-server-config-fd"),
                            InheritedDescriptor(
                                source: shellConfigPair.0,
                                target: Self.serviceShellDescriptor,
                                argument: "--nucleus-shell-config-fd"),
                            InheritedDescriptor(
                                source: controlConfigPair.0,
                                target: Self.serviceControlDescriptor,
                                argument: "--nucleus-control-config-fd"),
                            InheritedDescriptor(
                                source: newAttachmentPair.0,
                                target: Self.serviceAttachmentDescriptor,
                                argument:
                                    SupervisorAttachmentChannel
                                    .descriptorArgument),
                        ],
                        sendsSessionConfiguration: false)
                    children = [configService, controlService]
                    let configReady = try waitForReadiness(
                        configService,
                        milestone: .configServiceReady,
                        monitoring: [configService, controlService])
                    try statusPublisher.publish(configReady)
                    try controlAttachments.send(
                        role: .configurationControl,
                        descriptor: controlConfigPair.1)
                    _ = close(controlConfigPair.1)

                    let renderControlPair =
                        try SessionChannel.socketPair()
                    try controlAttachments.send(
                        role: .renderServerControl,
                        descriptor: renderControlPair.0)
                    _ = close(renderControlPair.0)
                    let shellPolicyAttachmentPair =
                        try SessionChannel.socketPair()
                    shellPolicyAttachments = ShellPolicyAttachmentChannel(
                        owning: shellPolicyAttachmentPair.1)
                    compositor = try spawn(
                        role: .compositor,
                        command: arguments.compositor,
                        inheritedDescriptors: [
                            InheritedDescriptor(
                                source: renderConfigPair.1,
                                target: Self.childConfigServiceDescriptor,
                                argument:
                                    ConfigurationClientChannel
                                    .descriptorArgument),
                            InheritedDescriptor(
                                source: renderControlPair.1,
                                target: Self.renderServerControlDescriptor,
                                argument:
                                    RenderServerControlChannel
                                    .descriptorArgument),
                            InheritedDescriptor(
                                source: shellPolicyAttachmentPair.0,
                                target:
                                    Self.compositorShellPolicyAttachmentDescriptor,
                                argument:
                                    ShellPolicyAttachmentChannel
                                    .descriptorArgument),
                        ])
                    children = [
                        configService, controlService, compositor,
                    ]
                    let compositorReady = try waitForReadiness(
                        compositor,
                        milestone: .compositorReady,
                        monitoring: [
                            configService, controlService, compositor,
                        ])
                    try statusPublisher.publish(compositorReady)

                    let capability = dup(elevatedAuthority)
                    guard capability >= 0 else {
                        throw SupervisorFailure.system(
                            "duplicating shell control capability", errno)
                    }
                    shell = try spawnShell(
                        configurationDescriptor: shellConfigPair.1,
                        elevatedDescriptor: capability,
                        attachments: shellPolicyAttachments)
                    children = [
                        configService, controlService, compositor, shell,
                    ]
                    let shellReady = try waitForReadiness(
                        shell,
                        milestone: .shellReady,
                        monitoring: [
                            configService, controlService, compositor, shell,
                        ])
                    try statusPublisher.publish(shellReady)
                case .supervisor, .capability:
                    throw SupervisorFailure.childExited(
                        unexpectedExit.role, unexpectedExit.status)
                }
            }
        } catch SupervisorFailure.interrupted(let signal) {
            try? statusPublisher.publish(
                SessionReadinessMessage(
                    role: .supervisor,
                    milestone: .terminating,
                    detail: signal))
            terminateCapabilities(capabilities)
            terminateSession(children)
            return 128 + signal
        } catch {
            log("\(error)")
            try? statusPublisher.publish(
                SessionReadinessMessage(
                    role: .supervisor,
                    milestone: .failed,
                    detail: failureReason(error).rawValue))
            terminateCapabilities(capabilities)
            terminateSession(children)
            return 1
        }
    }

    private func failureReason(_ error: any Error) -> SessionFailureReason {
        guard let failure = error as? SupervisorFailure else {
            return .internalFailure
        }
        switch failure {
        case .childExited(.compositor, _):
            return .compositorExitedBeforeReady
        case .childExited(.shell, _):
            return .shellExitedBeforeReady
        case .childExited(.configService, _):
            return .configServiceExitedBeforeReady
        case .childExited(.controlService, _):
            return .controlServiceExitedBeforeReady
        case .readinessClosed(.compositor):
            return .compositorReadinessClosed
        case .readinessClosed(.shell):
            return .shellReadinessClosed
        case .readinessClosed(.configService):
            return .configServiceReadinessClosed
        case .readinessClosed(.controlService):
            return .controlServiceReadinessClosed
        case .invalidReadiness(.compositor):
            return .compositorReadinessInvalid
        case .invalidReadiness(.shell):
            return .shellReadinessInvalid
        case .invalidReadiness(.configService):
            return .configServiceReadinessInvalid
        case .invalidReadiness(.controlService):
            return .controlServiceReadinessInvalid
        case .startupTimedOut(.compositor):
            return .compositorStartupTimedOut
        case .startupTimedOut(.shell):
            return .shellStartupTimedOut
        case .startupTimedOut(.configService):
            return .configServiceStartupTimedOut
        case .startupTimedOut(.controlService):
            return .controlServiceStartupTimedOut
        case .usage, .system, .channel, .interrupted,
            .childExited(.supervisor, _),
            .childExited(.capability, _),
            .readinessClosed(.supervisor),
            .readinessClosed(.capability),
            .invalidReadiness(.supervisor),
            .invalidReadiness(.capability),
            .startupTimedOut(.supervisor),
            .startupTimedOut(.capability):
            return .internalFailure
        }
    }

    private func spawnShell(
        configurationDescriptor: Int32,
        elevatedDescriptor: Int32,
        attachments: ShellPolicyAttachmentChannel
    ) throws -> SupervisedChild {
        let policy = try issueShellPolicy(to: attachments)
        return try spawn(
            role: .shell,
            command: [arguments.shell],
            inheritedDescriptors: [
                InheritedDescriptor(
                    source: configurationDescriptor,
                    target: Self.childConfigServiceDescriptor,
                    argument:
                        ConfigurationClientChannel.descriptorArgument),
                InheritedDescriptor(
                    source: elevatedDescriptor,
                    target: Self.shellControlCapabilityDescriptor,
                    argument:
                        "--nucleus-shell-control-capability-fd"),
                InheritedDescriptor(
                    source: policy,
                    target: Self.shellPolicyDescriptor,
                    argument:
                        ShellPolicyChannel.descriptorArgument),
            ])
    }

    private func issueShellPolicy(
        to attachments: ShellPolicyAttachmentChannel
    ) throws -> Int32 {
        let policy = try SessionChannel.socketPair()
        do {
            try attachments.send(policyDescriptor: policy.0)
        } catch {
            _ = close(policy.0)
            _ = close(policy.1)
            throw error
        }
        _ = close(policy.0)
        return policy.1
    }

    private func createControlSocketDirectory() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let runtime = environment["XDG_RUNTIME_DIR"],
            runtime.hasPrefix("/"), !runtime.isEmpty
        else {
            throw SupervisorFailure.usage(
                "XDG_RUNTIME_DIR is required for the control service")
        }
        if environment["NUCLEUS_SESSION_RUNTIME_DIR"] == runtime {
            return runtime
        }
        let sessionID =
            environment["NUCLEUS_SESSION_ID"]
            ?? environment["WAYLAND_DISPLAY"]
            ?? "wayland-0"
        guard !sessionID.isEmpty, !sessionID.contains("/") else {
            throw SupervisorFailure.usage(
                "NUCLEUS_SESSION_ID must not contain '/'")
        }
        let nucleus = runtime + "/nucleus"
        let session = nucleus + "/" + sessionID
        for directory in [nucleus, session] {
            if unsafe mkdir(directory, 0o700) != 0, errno != EEXIST {
                throw SupervisorFailure.system(
                    "creating control socket directory", errno)
            }
            var metadata = stat()
            guard unsafe lstat(directory, &metadata) == 0,
                metadata.st_uid == geteuid(),
                metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                metadata.st_mode & 0o077 == 0
            else {
                throw SupervisorFailure.usage(
                    "control socket directory is not owner-only: \(directory)")
            }
        }
        return session
    }

    private struct InheritedDescriptor {
        let source: Int32
        let target: Int32
        let argument: String
    }

    private func spawnCapability(
        _ declaration: SessionCapabilityDeclaration,
        restartCount: UInt8
    ) throws -> SupervisedCapability {
        let child = try spawn(
            role: .capability,
            command: [
                declaration.executable,
                SessionCapabilityProcess.identifierArgument,
                declaration.identifier,
            ] + declaration.arguments,
            sendsSessionConfiguration: false,
            reportsReadiness: false)
        log(
            "spawned capability \(declaration.identifier) "
                + "pid=\(child.processID) "
                + "restart=\(restartCount)")
        return SupervisedCapability(
            declaration: declaration,
            processID: child.processID,
            restartCount: restartCount)
    }

    private func spawn(
        role: SessionProcessRole,
        command: [String],
        inheritedDescriptors: [InheritedDescriptor] = [],
        sendsSessionConfiguration: Bool = true,
        reportsReadiness: Bool = true
    ) throws -> SupervisedChild {
        let pipeDescriptors: (Int32, Int32)?
        if reportsReadiness {
            do {
                pipeDescriptors = try SessionChannel.socketPair()
            } catch {
                throw SupervisorFailure.channel("\(error)")
            }
        } else {
            pipeDescriptors = nil
        }
        let readDescriptor = pipeDescriptors?.0 ?? -1
        let configurationPair: (Int32, Int32)?
        if sendsSessionConfiguration {
            do {
                configurationPair = try SessionChannel.socketPair()
            } catch {
                if let pipeDescriptors {
                    _ = close(pipeDescriptors.0)
                    _ = close(pipeDescriptors.1)
                }
                inheritedDescriptors.forEach { _ = close($0.source) }
                throw SupervisorFailure.channel("\(error)")
            }
        } else {
            configurationPair = nil
        }

        var actions = unsafe posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        guard unsafe posix_spawn_file_actions_init(&actions) == 0,
            unsafe posix_spawnattr_init(&attributes) == 0
        else {
            if let pipeDescriptors {
                _ = close(pipeDescriptors.0)
                _ = close(pipeDescriptors.1)
            }
            if let configurationPair {
                _ = close(configurationPair.0)
                _ = close(configurationPair.1)
            }
            inheritedDescriptors.forEach { _ = close($0.source) }
            throw SupervisorFailure.system("posix_spawn initialization", errno)
        }
        defer {
            unsafe posix_spawn_file_actions_destroy(&actions)
            unsafe posix_spawnattr_destroy(&attributes)
        }
        let readinessActionsAdded: Bool
        if let pipeDescriptors {
            let duplicateResult = unsafe posix_spawn_file_actions_adddup2(
                &actions,
                pipeDescriptors.1,
                Self.childReadinessDescriptor)
            let closeReadResult = unsafe posix_spawn_file_actions_addclose(
                &actions,
                pipeDescriptors.0)
            let closeWriteResult = unsafe posix_spawn_file_actions_addclose(
                &actions,
                pipeDescriptors.1)
            readinessActionsAdded =
                duplicateResult == 0
                && closeReadResult == 0
                && closeWriteResult == 0
        } else {
            readinessActionsAdded = true
        }
        guard readinessActionsAdded,
            unsafe addDescriptorActions(
                &actions,
                configurationPair.map {
                    InheritedDescriptor(
                        source: $0.0,
                        target: Self.childConfigurationDescriptor,
                        argument: SessionConfiguration.descriptorArgument)
                },
                closingPeer: configurationPair?.1),
            inheritedDescriptors.allSatisfy({
                unsafe addDescriptorActions(
                    &actions, $0, closingPeer: nil)
            })
        else {
            if let pipeDescriptors {
                _ = close(pipeDescriptors.0)
                _ = close(pipeDescriptors.1)
            }
            if let configurationPair {
                _ = close(configurationPair.0)
                _ = close(configurationPair.1)
            }
            inheritedDescriptors.forEach { _ = close($0.source) }
            throw SupervisorFailure.system("child descriptor actions", errno)
        }

        var defaultSignals = sigset_t()
        var emptyMask = sigset_t()
        unsafe sigemptyset(&defaultSignals)
        unsafe sigemptyset(&emptyMask)
        for signal in [SIGCHLD, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] {
            unsafe sigaddset(&defaultSignals, signal)
        }
        guard
            unsafe posix_spawnattr_setsigdefault(
                &attributes,
                &defaultSignals) == 0,
            unsafe posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
            unsafe posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_SETSIGDEF
                        | POSIX_SPAWN_SETSIGMASK
                        | POSIX_SPAWN_SETPGROUP)) == 0,
            unsafe posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            if let pipeDescriptors {
                _ = close(pipeDescriptors.0)
                _ = close(pipeDescriptors.1)
            }
            if let configurationPair {
                _ = close(configurationPair.0)
                _ = close(configurationPair.1)
            }
            inheritedDescriptors.forEach { _ = close($0.source) }
            throw SupervisorFailure.system("child signal attributes", errno)
        }

        var childArguments = [
            command[0],
            SessionProcessRole.argument,
            String(role.rawValue),
        ]
        if reportsReadiness {
            childArguments += [
                SessionReadinessReporter.descriptorArgument,
                String(Self.childReadinessDescriptor),
            ]
        }
        if configurationPair != nil {
            childArguments += [
                SessionConfiguration.descriptorArgument,
                String(Self.childConfigurationDescriptor),
            ]
        }
        for inherited in inheritedDescriptors {
            childArguments += [
                inherited.argument,
                String(inherited.target),
            ]
        }
        childArguments += command.dropFirst()
        let storage: [UnsafeMutablePointer<CChar>?] =
            unsafe childArguments.map { unsafe strdup($0) } + [nil]
        defer { unsafe storage.forEach { unsafe free($0) } }
        var processID = pid_t()
        let result = storage.withUnsafeBufferPointer { buffer in
            unsafe posix_spawnp(
                &processID,
                buffer[0]!,
                &actions,
                &attributes,
                UnsafeMutablePointer(mutating: buffer.baseAddress!),
                environ)
        }
        if let pipeDescriptors {
            _ = close(pipeDescriptors.1)
        }
        if let configurationPair { _ = close(configurationPair.0) }
        inheritedDescriptors.forEach { _ = close($0.source) }
        guard result == 0 else {
            if let pipeDescriptors {
                _ = close(pipeDescriptors.0)
            }
            if let configurationPair { _ = close(configurationPair.1) }
            throw SupervisorFailure.system(
                "launching \(command[0])",
                Int32(result))
        }
        if let configurationPair {
            do {
                try SessionChannel.send(
                    arguments.configuration.encoded,
                    to: configurationPair.1)
            } catch {
                _ = close(configurationPair.1)
                if let pipeDescriptors {
                    _ = close(pipeDescriptors.0)
                }
                _ = kill(-processID, SIGKILL)
                while waitpid(processID, nil, 0) < 0, errno == EINTR {}
                throw error
            }
            _ = close(configurationPair.1)
        }
        log("spawned \(role) pid=\(processID)")
        return SupervisedChild(
            role: role,
            processID: processID,
            readinessDescriptor: readDescriptor)
    }

    private func addDescriptorActions(
        _ actions: inout posix_spawn_file_actions_t,
        _ inherited: InheritedDescriptor?,
        closingPeer: Int32?
    ) -> Bool {
        guard let inherited else { return true }
        guard
            unsafe posix_spawn_file_actions_adddup2(
                &actions, inherited.source, inherited.target) == 0,
            unsafe posix_spawn_file_actions_addclose(
                &actions, inherited.source) == 0
        else { return false }
        if let closingPeer {
            return unsafe posix_spawn_file_actions_addclose(
                &actions, closingPeer) == 0
        }
        return true
    }

    private func waitForReadiness(
        _ child: SupervisedChild,
        milestone: SessionMilestone,
        monitoring children: [SupervisedChild],
        timeoutMilliseconds: Int32? = nil
    ) throws -> SessionReadinessMessage {
        defer { _ = close(child.readinessDescriptor) }
        let deadline =
            Self.monotonicNanoseconds()
            + UInt64(
                timeoutMilliseconds
                    ?? arguments.startupTimeoutMilliseconds) * 1_000_000
        while true {
            var descriptors = [
                pollfd(
                    fd: child.readinessDescriptor,
                    events: Int16(POLLIN),
                    revents: 0),
                pollfd(
                    fd: signalDescriptor,
                    events: Int16(POLLIN),
                    revents: 0),
            ]
            let now = Self.monotonicNanoseconds()
            guard now < deadline else {
                throw SupervisorFailure.startupTimedOut(child.role)
            }
            let remainingMilliseconds = max(
                1,
                Int32(
                    min(
                        UInt64(Int32.max),
                        (deadline - now + 999_999) / 1_000_000)))
            let pollResult = unsafe poll(
                &descriptors,
                nfds_t(descriptors.count),
                remainingMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw SupervisorFailure.system("readiness poll", errno)
            }
            if pollResult == 0 {
                throw SupervisorFailure.startupTimedOut(child.role)
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 {
                try processSignals(monitoring: children)
            }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let bytes: [UInt8]
                do {
                    bytes = try SessionChannel.receive(
                        from: child.readinessDescriptor,
                        maximumBytes: SessionReadinessMessage.encodedSize)
                } catch {
                    throw SupervisorFailure.readinessClosed(child.role)
                }
                guard let message = SessionReadinessMessage(encoded: bytes),
                    message.role == child.role,
                    message.milestone == milestone
                else {
                    throw SupervisorFailure.invalidReadiness(child.role)
                }
                return message
            }
            if descriptors[0].revents
                & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
            {
                throw SupervisorFailure.readinessClosed(child.role)
            }
        }
    }

    private func waitForSessionExit(
        _ children: [SupervisedChild],
        capabilities: [SupervisedCapability]
    ) throws -> UnexpectedProcessExit {
        while true {
            if let exit = reapExitedProcess(
                children,
                capabilities: capabilities)
            {
                return exit
            }
            var descriptor = pollfd(
                fd: signalDescriptor,
                events: Int16(POLLIN),
                revents: 0)
            let result = unsafe poll(&descriptor, 1, -1)
            if result < 0 {
                if errno == EINTR { continue }
                throw SupervisorFailure.system("session wait", errno)
            }
            guard descriptor.revents & Int16(POLLIN) != 0 else { continue }
            let signals = drainSignals()
            if let signal = signals.first(where: {
                $0 == SIGINT || $0 == SIGTERM || $0 == SIGHUP
            }) {
                throw SupervisorFailure.interrupted(signal)
            }
        }
    }

    private func reapExitedProcess(
        _ children: [SupervisedChild],
        capabilities: [SupervisedCapability]
    ) -> UnexpectedProcessExit? {
        for child in children {
            var waitStatus: Int32 = 0
            let waited = unsafe waitpid(
                child.processID, &waitStatus, WNOHANG)
            guard waited == child.processID else { continue }
            return .session(
                UnexpectedSessionExit(
                    role: child.role,
                    status: Self.exitStatus(waitStatus)))
        }
        for capability in capabilities {
            var waitStatus: Int32 = 0
            let waited = unsafe waitpid(
                capability.processID, &waitStatus, WNOHANG)
            guard waited == capability.processID else { continue }
            return .capability(
                identifier: capability.declaration.identifier,
                status: Self.exitStatus(waitStatus))
        }
        return nil
    }

    private func processSignals(monitoring children: [SupervisedChild]) throws {
        let signals = drainSignals()
        if let signal = signals.first(where: {
            $0 == SIGINT || $0 == SIGTERM || $0 == SIGHUP
        }) {
            throw SupervisorFailure.interrupted(signal)
        }
        guard signals.contains(SIGCHLD) else { return }
        for child in children {
            var waitStatus: Int32 = 0
            let waited = unsafe waitpid(
                child.processID, &waitStatus, WNOHANG)
            if waited == child.processID {
                throw SupervisorFailure.childExited(
                    child.role,
                    Self.exitStatus(waitStatus))
            }
        }
    }

    private func drainSignals() -> [Int32] {
        var values: [Int32] = []
        while true {
            let signal = nucleus_session_consume_signal(signalDescriptor)
            guard signal >= 0 else { break }
            values.append(signal)
        }
        return values
    }

    private func terminate(
        _ children: [SupervisedChild],
        graceMilliseconds: UInt64 = 1_000,
        gracefulRootOnly: Bool = false
    ) {
        let processGroups = Set(children.map(\.processID))
        var remaining = processGroups
        for processGroup in processGroups {
            _ = kill(
                gracefulRootOnly ? processGroup : -processGroup,
                SIGTERM)
        }

        let deadline =
            Self.monotonicNanoseconds()
            + graceMilliseconds * 1_000_000
        while !remaining.isEmpty,
            Self.monotonicNanoseconds() < deadline
        {
            for processID in Array(remaining) {
                var waitStatus: Int32 = 0
                let waited = unsafe waitpid(
                    processID, &waitStatus, WNOHANG)
                if waited == processID || (waited < 0 && errno == ECHILD) {
                    remaining.remove(processID)
                }
            }
            guard !remaining.isEmpty else { break }
            var descriptor = pollfd(
                fd: signalDescriptor,
                events: Int16(POLLIN),
                revents: 0)
            _ = unsafe poll(&descriptor, 1, 20)
            _ = drainSignals()
        }
        // A root may have exited during the grace period while a descendant
        // ignored SIGTERM. Kill every original process group, not only roots
        // still visible to waitpid.
        for processGroup in processGroups {
            _ = kill(-processGroup, SIGKILL)
        }
        for processID in remaining {
            while waitpid(processID, nil, 0) < 0, errno == EINTR {}
        }
    }

    private func terminateCapabilities(
        _ capabilities: [SupervisedCapability]
    ) {
        let graceMilliseconds =
            UInt64(
                capabilities.map {
                    $0.declaration.shutdownTimeoutSeconds
                }.max() ?? 1) * 1_000
        terminate(
            capabilities.map {
                SupervisedChild(
                    role: .capability,
                    processID: $0.processID,
                    readinessDescriptor: -1)
            },
            graceMilliseconds: graceMilliseconds,
            gracefulRootOnly: true)
    }

    private func terminateSession(_ children: [SupervisedChild]) {
        revokePublicControlAccess()
        let control = children.filter { $0.role == .controlService }
        terminate(children.filter { $0.role != .controlService })
        terminate(control)
    }

    private func revokePublicControlAccess() {
        guard let controlSocketPath else { return }
        if unsafe unlink(controlSocketPath) != 0, errno != ENOENT {
            log("failed to revoke public control socket: errno \(errno)")
        }
    }

    private static func exitStatus(_ waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0
            ? (waitStatus >> 8) & 0xff
            : 128 + signal
    }

    private static func monotonicNanoseconds() -> UInt64 {
        var time = timespec()
        unsafe clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1_000_000_000
            + UInt64(time.tv_nsec)
    }

    private func log(_ message: String) {
        NucleusLogger(subsystem: "session-supervisor").info(message)
    }
}

let status: Int32
do {
    let arguments = try SupervisorArguments.parse(CommandLine.arguments)
    status = try SessionSupervisor(arguments: arguments).run()
} catch SupervisorFailure.usage(let usage) {
    print(usage)
    status = CommandLine.arguments.contains("--help") ? 0 : 64
} catch {
    NucleusLogger(subsystem: "session-supervisor").error("\(error)")
    status = 1
}
exit(status)
