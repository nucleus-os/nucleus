import NucleusConfig
import NucleusSessionProtocol

extension CompositorRuntime {
    func installShellPolicyPublication() {
        policyServices.policy.acceptedActionSink = { [weak self]
            action, configurationIndex, value, epoch, generation in
            self?.publishAcceptedShellAction(
                actionCode: action,
                configurationIndex: configurationIndex,
                value: value,
                epoch: epoch,
                generation: generation)
        }
        policyServices.policy.windowMenuSink = { [weak self]
            windowID, x, y, capabilities in
            self?.publishWindowMenu(
                windowID: windowID,
                x: x,
                y: y,
                capabilities: capabilities)
        }
    }

    func receiveShellPolicyAttachment() {
        guard let shellPolicyAttachments else { return }
        do {
            let attachment = try shellPolicyAttachments.receive()
            revokeShellSession()
            let policy = ShellPolicyChannel(
                owning: attachment.take())
            shellPolicyChannel = policy
            try policy.send(ShellPolicyPublication(
                kind: .ready,
                configurationEpoch: configurationEpoch,
                configurationGeneration: configurationGeneration))
            logRuntime("shell session: installed policy generation")
        } catch {
            logRuntime("shell policy attachment failed: \(error)")
            revokeShellSession()
        }
    }

    func receiveShellPolicyRequest() {
        guard let channel = shellPolicyChannel else { return }
        do {
            let request = try channel.receiveRequest()
            switch request.kind {
            case .setCursorTheme:
                guard let theme = request.cursorTheme,
                      !theme.isEmpty,
                      theme.utf8.count <= 4 * 1024
                else {
                    throw ShellPolicyChannelFailure.invalidAttachment
                }
                policyServices.cursorTheme.applyNamed(theme)
                frameDemand.requestFrame()
            case .selectWindowMenuItem:
                guard let windowID = request.windowID,
                      windowID == offeredWindowMenuID,
                      let verb = request.windowMenuVerb
                else {
                    throw ShellPolicyChannelFailure.invalidAttachment
                }
                offeredWindowMenuID = nil
                server.inputControl?.windowMenuSelected(
                    windowID: windowID,
                    verb: Int32(bitPattern: verb))
            }
        } catch {
            logRuntime("shell policy request failed: \(error)")
            revokeShellSession()
        }
    }

    func revokeShellSession() {
        offeredWindowMenuID = nil
        shellPolicyChannel = nil
    }

    private func publishAcceptedShellAction(
        actionCode: UInt8,
        configurationIndex: UInt32,
        value: UInt32,
        epoch: ConfigurationServiceEpoch,
        generation: ConfigurationGeneration
    ) {
        _ = value
        guard configurationIndex != .max,
              Int(configurationIndex) < liveConfiguration.binds.count
        else { return }
        let action =
            liveConfiguration.binds[Int(configurationIndex)].action
        guard Self.shellActionCode(action) == actionCode else {
            logRuntime(
                "shell action: binding index/action mismatch")
            return
        }
        do {
            try shellPolicyChannel?.send(ShellPolicyPublication(
                kind: .acceptedAction,
                action: action,
                configurationIndex: configurationIndex,
                configurationEpoch: epoch,
                configurationGeneration: generation))
        } catch {
            revokeShellSession()
        }
    }

    func publishControlShellAction(_ action: BindAction) {
        guard action.runtimeOwner == .shell,
              action != .showWindowMenu
        else { return }
        do {
            try shellPolicyChannel?.send(ShellPolicyPublication(
                kind: .acceptedAction,
                action: action,
                configurationEpoch: configurationEpoch,
                configurationGeneration: configurationGeneration))
        } catch {
            revokeShellSession()
        }
    }

    private func publishWindowMenu(
        windowID: UInt64,
        x: Double,
        y: Double,
        capabilities: UInt32
    ) {
        offeredWindowMenuID = windowID
        do {
            try shellPolicyChannel?.send(ShellPolicyPublication(
                kind: .windowMenuOffered,
                action: .showWindowMenu,
                configurationEpoch: configurationEpoch,
                configurationGeneration: configurationGeneration,
                windowID: windowID,
                x: x,
                y: y,
                windowCapabilities: capabilities))
        } catch {
            revokeShellSession()
        }
    }

    private static func shellActionCode(
        _ action: BindAction
    ) -> UInt8? {
        switch action {
        case .launch:
            1
        case .toggleHotkeyOverlay:
            2
        case .dismissHotkeyOverlay:
            3
        case .showWindowMenu:
            4
        case .closeWindow, .tile, .adjustBackdropIntensity,
             .activateWorkspace, .moveWindowToWorkspace:
            nil
        }
    }
}
