import Foundation
import Dispatch
import Glibc
import NucleusIPCTransport
import NucleusSessionProtocol
import NucleusControlClient

private enum FixtureFailure: Error {
    case missingDirectory
    case malformedDescriptor
}

private func writeText(_ value: String, to path: String) throws {
    try Data(value.utf8).write(
        to: URL(fileURLWithPath: path),
        options: .atomic)
}

private func waitForFile(_ path: String) {
    while unsafe access(path, F_OK) != 0 { usleep(10_000) }
}

private func argumentValue(
    following argument: String,
    in arguments: [String]
) -> String? {
    guard let index = arguments.firstIndex(of: argument),
          arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
}

private func descriptor(
    following argument: String,
    in arguments: [String]
) throws -> Int32 {
    guard let index = arguments.firstIndex(of: argument),
          arguments.indices.contains(index + 1),
          let value = Int32(arguments[index + 1])
    else { throw FixtureFailure.malformedDescriptor }
    return value
}

private func run() throws -> Int32 {
    guard let directoryValue = unsafe getenv(
        "NUCLEUS_SESSION_FIXTURE_DIRECTORY")
    else { throw FixtureFailure.missingDirectory }
    let directory = unsafe String(cString: directoryValue)
    if let capabilityID = argumentValue(
        following: SessionCapabilityProcess.identifierArgument,
        in: CommandLine.arguments)
    {
        return try runCapability(
            identifier: capabilityID,
            directory: directory)
    }
    let role = try SessionProcessRole.inherited()
    let roleName = role == .compositor ? "compositor" : "shell"
    let waylandDisplay = unsafe getenv("WAYLAND_DISPLAY").map {
        unsafe String(cString: $0)
    } ?? "<missing>"
    try writeText(
        waylandDisplay,
        to: directory + "/\(roleName)-wayland-display")
    let modeName = "NUCLEUS_SESSION_FIXTURE_"
        + roleName.uppercased() + "_MODE"
    let mode: String
    if let modeValue = unsafe getenv(modeName) {
        mode = unsafe String(cString: modeValue)
    } else {
        mode = "ready-wait"
    }
    let exitedOnceMarker = directory + "/\(roleName)-exited-once"
    if mode == "exit-after-session-ready-once-with-restart-delay",
       unsafe access(exitedOnceMarker, F_OK) == 0
    {
        usleep(250_000)
    }

    let configuration = try SessionConfiguration.inherited()
    let shellPolicyChannel: ShellPolicyChannel?
    let shellAttachmentChannel: ShellPolicyAttachmentChannel?
    switch role {
    case .compositor:
        shellPolicyChannel = nil
        shellAttachmentChannel =
            try ShellPolicyAttachmentChannel.inherited()
        guard shellAttachmentChannel != nil else {
            throw FixtureFailure.malformedDescriptor
        }
    case .shell:
        shellPolicyChannel = try ShellPolicyChannel.inherited()
        shellAttachmentChannel = nil
        guard shellPolicyChannel != nil else {
            throw FixtureFailure.malformedDescriptor
        }
        try writeText(
            "valid",
            to: directory + "/shell-policy-endpoint-\(getpid())")
    case .supervisor, .configService, .controlService:
        throw ConfigurationChannelFailure.unexpectedPublication
    }
    defer {
        _ = shellPolicyChannel
        _ = shellAttachmentChannel
    }
    guard let configurationChannel =
            try ConfigurationClientChannel.inherited()
    else { throw FixtureFailure.malformedDescriptor }
    try configurationChannel.send(.subscribe(
        as: role == .compositor ? .shell : .renderServer))
    guard try configurationChannel.receive().kind == .rejected else {
        throw ConfigurationChannelFailure.unexpectedPublication
    }
    let publication = try configurationChannel.subscribe(
        as: role == .compositor ? .renderServer : .shell)
    switch role {
    case .compositor:
        guard case .some = publication.renderServerConfiguration else {
            throw ConfigurationChannelFailure.unexpectedPublication
        }
    case .shell:
        guard case .some = publication.shellConfiguration else {
            throw ConfigurationChannelFailure.unexpectedPublication
        }
    case .supervisor, .configService, .controlService:
        throw ConfigurationChannelFailure.unexpectedPublication
    }
    try configurationChannel.acknowledge(publication)
    if role == .compositor {
        let controlChannel = try RenderServerControlChannel.inherited()
        let ownerEpoch = RenderServerEpoch(high: 10, low: 20)
        try controlChannel.send(RenderServerControlPublication(
            result: .ready,
            ownerEpoch: ownerEpoch,
            configurationEpoch: publication.epoch,
            appliedConfigurationGeneration: publication.generation,
            version: "fixture-render-server 1"))
        DispatchQueue.global().async {
            while true {
                let request: RenderServerControlRequestEnvelope
                do {
                    request = try controlChannel.receive(
                        RenderServerControlRequestEnvelope.self)
                } catch {
                    let message = "fixture owner receive failed: \(error)\n"
                    _ = message.withCString {
                        unsafe write(STDERR_FILENO, $0, strlen($0))
                    }
                    return
                }
                let response: RenderServerControlPublication
                switch request.request {
                case .version:
                    response = RenderServerControlPublication(
                        requestID: request.requestID,
                        result: .completed,
                        ownerEpoch: ownerEpoch,
                        configurationEpoch: publication.epoch,
                        appliedConfigurationGeneration:
                            publication.generation,
                        version: "fixture-render-server 1")
                case .outputs:
                    response = RenderServerControlPublication(
                        requestID: request.requestID,
                        result: .completed,
                        ownerEpoch: ownerEpoch,
                        configurationEpoch: publication.epoch,
                        appliedConfigurationGeneration:
                            publication.generation,
                        outputs: [RenderServerOutputSnapshot(
                            id: 1,
                            name: "fixture-output",
                            width: 1920,
                            height: 1080,
                            refreshMillihertz: 60_000,
                            scale: 1,
                            x: 0,
                            y: 0,
                            enabled: true)])
                case .activeBindings:
                    response = RenderServerControlPublication(
                        requestID: request.requestID,
                        result: .completed,
                        ownerEpoch: ownerEpoch,
                        configurationEpoch: publication.epoch,
                        appliedConfigurationGeneration:
                            publication.generation,
                        activeBindings:
                            publication.renderServerConfiguration?.binds)
                case .action:
                    response = RenderServerControlPublication(
                        requestID: request.requestID,
                        result: .completed,
                        ownerEpoch: ownerEpoch,
                        configurationEpoch: publication.epoch,
                        appliedConfigurationGeneration:
                            publication.generation)
                }
                try? controlChannel.send(response)
            }
        }
    }
    try writeText(
        configuration.hexEncoded,
        to: directory + "/\(roleName)-configuration")
    try writeText(
        "\(publication.epoch.high):\(publication.epoch.low):"
            + "\(publication.generation.rawValue)",
        to: directory + "/\(roleName)-live-configuration")
    try writeText(
        String(getpid()),
        to: directory + "/\(roleName)-pid")

    if mode == "wait-before-ready" {
        waitForFile(directory + "/release-\(roleName)")
    }
    if mode == "exit-before-ready" { return 71 }
    if mode == "missing-readiness" { return 0 }
    if mode == "malformed-readiness" {
        let readinessDescriptor = try descriptor(
            following: SessionReadinessReporter.descriptorArgument,
            in: CommandLine.arguments)
        var bytes = [UInt8](repeating: 0xa5, count: 12)
        _ = unsafe write(readinessDescriptor, &bytes, bytes.count)
        _ = close(readinessDescriptor)
        return 0
    }

    let reporter = try SessionReadinessReporter.inherited(role: role)
    try reporter?.report(
        role == .compositor ? .compositorReady : .shellReady)
    try writeText("ready", to: directory + "/\(roleName)-ready")
    if let shellAttachmentChannel {
        DispatchQueue.global().async {
            var attachmentCount = 0
            var activeAttachment:
                NucleusIPCTransport.OwnedFileDescriptor?
            while true {
                do {
                    activeAttachment =
                        try shellAttachmentChannel.receive()
                    attachmentCount += 1
                    try writeText(
                        String(attachmentCount),
                        to: directory + "/shell-attachment-count")
                    _ = activeAttachment
                } catch {
                    return
                }
            }
        }
    }

    if mode == "elevated-replace" {
        let capability = try descriptor(
            following:
                ControlSocket.elevatedCapabilityDescriptorArgument,
            in: CommandLine.arguments)
        let runtimeDirectory = unsafe getenv("XDG_RUNTIME_DIR").map {
            unsafe String(cString: $0)
        } ?? directory
        let socket = runtimeDirectory + "/control.sock"
        let response = try ControlClient(path: socket).send(
            .replaceConfiguration("{}"),
            capabilityDescriptor: capability)
        try writeText(
            response == .completed ? "completed" : "\(response)",
            to: directory + "/elevated-replace-result")
    }

    if mode == "exit-after-peer-ready" {
        let peer = role == .compositor ? "shell" : "compositor"
        waitForFile(directory + "/\(peer)-ready")
        return role == .compositor ? 72 : 73
    }
    if mode == "exit-after-ready" {
        return role == .compositor ? 72 : 73
    }
    if mode == "exit-after-session-ready-once"
        || mode == "exit-after-session-ready-once-with-restart-delay"
    {
        let peer = role == .compositor ? "shell" : "compositor"
        waitForFile(directory + "/\(peer)-ready")
        if unsafe access(exitedOnceMarker, F_OK) != 0 {
            try writeText("exited", to: exitedOnceMarker)
            return role == .compositor ? 72 : 73
        }
        try writeText("restarted", to: directory + "/\(roleName)-restarted")
    }
    while true { pause() }
}

private func runCapability(
    identifier: String,
    directory: String
) throws -> Int32 {
    let mode = unsafe getenv(
        "NUCLEUS_SESSION_FIXTURE_CAPABILITY_MODE").map {
            unsafe String(cString: $0)
        } ?? "ready-wait"
    let pidPath = directory + "/capability-pid"
    let firstPIDPath = directory + "/capability-first-pid"
    let exitedOncePath = directory + "/capability-exited-once"
    try writeText(identifier, to: directory + "/capability-identifier")
    try writeText(String(getpid()), to: pidPath)
    if unsafe access(firstPIDPath, F_OK) != 0 {
        try writeText(String(getpid()), to: firstPIDPath)
    }
    if mode == "exit-once-nonzero",
       unsafe access(exitedOncePath, F_OK) != 0
    {
        try writeText("exited", to: exitedOncePath)
        return 79
    }
    if mode == "exit-zero" {
        try writeText("exited", to: directory + "/capability-exited-zero")
        return 0
    }
    if unsafe access(exitedOncePath, F_OK) == 0 {
        try writeText("restarted", to: directory + "/capability-restarted")
    }
    while true { pause() }
}

do {
    exit(try run())
} catch {
    let line = "nucleus-session-fixture: \(error)\n"
    _ = line.withCString {
        unsafe write(STDERR_FILENO, $0, strlen($0))
    }
    exit(70)
}
