import NucleusSessionProtocol
package import NucleusWindowClientWayland

@MainActor
extension ShellHost {
    func receiveConfigurationPublication() {
        guard let configurationChannel else { return }
        do {
            let publication = try configurationChannel.receive()
            if publication.kind == .diagnostics {
                reportConfigurationDiagnostics(publication.diagnostics)
                return
            }
            guard publication.kind == .snapshot,
                publication.projectionKind == .shell,
                let projection = publication.shellConfiguration
            else {
                writeErr(
                    "nucleus-shell: unexpected configuration publication")
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
            liveConfiguration = projection
            configurationEpoch = publication.epoch
            configurationGeneration = publication.generation
            applyShellPolicyPreferences()
            reportConfigurationDiagnostics(publication.diagnostics)
            try configurationChannel.acknowledge(publication)
        } catch {
            writeErr(
                "nucleus-shell: configuration subscription failed: \(error)")
        }
    }

    func applyShellPolicyPreferences() {
        configureIdleNotification()
        if policyReady, let policyChannel {
            do {
                try policyChannel.send(
                    ShellPolicyRequest(
                        kind: .setCursorTheme,
                        cursorTheme: liveConfiguration.cursorTheme))
            } catch {
                writeErr(
                    "nucleus-shell: cursor preference publication failed: \(error)")
                running = false
            }
        }
    }

    func configureIdleNotification() {
        idleNotification?.destroy()
        idleNotification = nil
        guard liveConfiguration.idleTimeoutSeconds > 0,
            liveConfiguration.idleTimeoutSeconds
                <= UInt32.max / 1000,
            let notification = NucleusDesktopIdleNotification(
                client: client,
                timeoutMilliseconds:
                    liveConfiguration.idleTimeoutSeconds * 1000)
        else { return }
        notification.onIdled = { [weak self] in
            guard let self else { return }
            actionDispatcher.receiveIdleState(
                .idle,
                epoch: configurationEpoch,
                generation: configurationGeneration)
            _ = lockController?.lock()
            requestRender(nativeSceneChanged: true)
        }
        notification.onResumed = { [weak self] in
            guard let self else { return }
            actionDispatcher.receiveIdleState(
                .active,
                epoch: configurationEpoch,
                generation: configurationGeneration)
        }
        idleNotification = notification
        _ = client.flush()
    }

    private func reportConfigurationDiagnostics(
        _ diagnostics: [ConfigurationDiagnosticPublication]
    ) {
        for diagnostic in diagnostics {
            let path =
                diagnostic.keyPath.isEmpty
                ? ""
                : diagnostic.keyPath.joined(separator: ".") + ": "
            writeErr(
                "nucleus-shell: config: \(path)\(diagnostic.message)")
        }
    }
}
