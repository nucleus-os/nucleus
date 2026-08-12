import Glibc
import NucleusDiagnostics
internal import NucleusRenderServerRuntime
import NucleusSessionProtocol

// Keep process policy here: decode launch state, enter the framework, map exit.
do {
    let session = try SessionConfiguration.inherited()
    guard
        let configurationChannel =
            try ConfigurationClientChannel.inherited()
    else {
        throw ConfigurationChannelFailure.invalidDescriptor("<missing>")
    }
    let publication = try configurationChannel.subscribe(as: .renderServer)
    guard let liveConfiguration = publication.renderServerConfiguration else {
        throw ConfigurationChannelFailure.unexpectedPublication
    }
    for diagnostic in publication.diagnostics {
        NucleusLogger(subsystem: "compositor").error(
            "config: \(diagnostic.message)")
    }
    try configurationChannel.acknowledge(publication)
    let controlChannel = try RenderServerControlChannel.inherited()
    let shellPolicyAttachments =
        try ShellPolicyAttachmentChannel.inherited()
    let readiness = try SessionReadinessReporter.inherited(role: .compositor)
    let status = await runNucleusCompositor(
        configuration: session,
        liveConfiguration: liveConfiguration,
        configurationEpoch: publication.epoch,
        configurationGeneration: publication.generation,
        configurationChannel: configurationChannel,
        controlChannel: controlChannel,
        shellPolicyAttachments: shellPolicyAttachments,
        readinessReporter: readiness)
    if status != 0 {
        NucleusLogger(subsystem: "compositor").error(
            "render server terminated with status \(status)")
    }
    exit(status)
} catch {
    NucleusLogger(subsystem: "compositor").error(
        "invalid session launch contract: \(error)")
    exit(1)
}
