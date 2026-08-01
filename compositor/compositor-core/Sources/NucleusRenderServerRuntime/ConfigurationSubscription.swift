import NucleusConfig
import NucleusSessionProtocol

extension CompositorRuntime {
    func receiveConfigurationPublication() {
        guard let configurationChannel else { return }
        do {
            let publication = try configurationChannel.receive()
            if publication.kind == .diagnostics {
                reportConfigurationDiagnostics(publication.diagnostics)
                return
            }
            guard publication.kind == .snapshot,
                publication.projectionKind == .renderServer,
                let projection =
                    publication.renderServerConfiguration
            else {
                logRuntime("config: rejected unexpected publication")
                return
            }
            if publication.epoch == configurationEpoch {
                guard publication.generation > configurationGeneration else {
                    try configurationChannel.send(
                        .reject(
                            epoch: publication.epoch,
                            generation: publication.generation,
                            reason: "stale generation"))
                    return
                }
            }
            configurationEpoch = publication.epoch
            configurationGeneration = publication.generation
            applyConfiguration(projection)
            reportConfigurationDiagnostics(publication.diagnostics)
            try configurationChannel.acknowledge(publication)
        } catch {
            logRuntime("config: subscription failed: \(error)")
        }
    }

    private func applyConfiguration(
        _ projection: RenderServerConfiguration
    ) {
        let previous = liveConfiguration
        liveConfiguration = projection
        if projection.input != previous.input {
            waylandRuntime.updateInputConfiguration(projection.input)
        }
        if projection.binds != previous.binds {
            policyServices.adoptConfiguration(
                binds: projection.binds,
                epoch: configurationEpoch,
                generation: configurationGeneration)
        } else {
            policyServices.adoptConfigurationVersion(
                epoch: configurationEpoch,
                generation: configurationGeneration)
        }
        if projection.outputs != previous.outputs {
            outputTopology.outputOverrides = projection.outputs
            _ = outputTopology.reconcile(forceReattach: true)
        }
        logRuntime("config: adopted generation \(configurationGeneration.rawValue + 1)")
    }

    private func reportConfigurationDiagnostics(
        _ diagnostics: [ConfigurationDiagnosticPublication]
    ) {
        for diagnostic in diagnostics {
            let path =
                diagnostic.keyPath.isEmpty
                ? ""
                : diagnostic.keyPath.joined(separator: ".") + ": "
            logRuntime("config: \(path)\(diagnostic.message)")
        }
    }
}
