import NucleusConfig
import NucleusDiagnostics
internal import NucleusSessionProtocol

#if canImport(Glibc)
import Glibc
#endif

/// Runs one native shell process against the inherited session contract.
///
/// The executable target intentionally delegates its complete composition root
/// here so loading `NucleusShell` loads exactly one first-party framework:
/// `NucleusShellKit`.
@MainActor
package func runShell() async -> Int32 {
    let socket: String?
    if let value = unsafe getenv("WAYLAND_DISPLAY") {
        socket = unsafe String(cString: value)
    } else {
        socket = nil
    }

    let configuration: SessionConfiguration
    let liveConfiguration: ShellConfiguration
    let configurationEpoch: ConfigurationServiceEpoch
    let configurationGeneration: ConfigurationGeneration
    let configurationChannel: ConfigurationClientChannel
    let readiness: SessionReadinessReporter?
    let policyChannel: ShellPolicyChannel?
    do {
        configuration = try SessionConfiguration.inherited()
        guard
            let inheritedChannel =
                try ConfigurationClientChannel.inherited()
        else {
            throw ConfigurationChannelFailure.invalidDescriptor("<missing>")
        }
        let publication = try inheritedChannel.subscribe(as: .shell)
        guard let projection = publication.shellConfiguration else {
            throw ConfigurationChannelFailure.unexpectedPublication
        }
        for diagnostic in publication.diagnostics {
            NucleusLogger(subsystem: "shell").error(
                "config: \(diagnostic.message)")
        }
        try inheritedChannel.acknowledge(publication)
        liveConfiguration = projection
        configurationEpoch = publication.epoch
        configurationGeneration = publication.generation
        configurationChannel = inheritedChannel
        readiness = try SessionReadinessReporter.inherited(role: .shell)
        policyChannel = try ShellPolicyChannel.inherited()
    } catch {
        NucleusLogger(subsystem: "shell").error(
            "invalid session readiness channel: \(error)")
        return 1
    }

    guard
        let host = ShellHost(
            socketName: socket,
            waylandDescriptor: nil,
            configuration: configuration,
            liveConfiguration: liveConfiguration,
            configurationEpoch: configurationEpoch,
            configurationGeneration: configurationGeneration,
            configurationChannel: configurationChannel,
            policyChannel: policyChannel)
    else {
        NucleusLogger(subsystem: "shell").error(
            "could not connect to the compositor "
                + "(WAYLAND_DISPLAY=\(socket ?? "<default>")) or bring up the render device")
        return 1
    }
    await host.run(readinessReporter: readiness)
    return 0
}
