import NucleusConfig
internal import NucleusSessionProtocol

extension CompositorRuntime {
    func publishControlReadiness() {
        try? controlChannel.send(
            RenderServerControlPublication(
                result: .ready,
                ownerEpoch: controlEpoch,
                configurationEpoch: configurationEpoch,
                appliedConfigurationGeneration: configurationGeneration,
                version: Self.controlVersion))
    }

    func receiveControlRequest() {
        do {
            let envelope = try controlChannel.receive(
                RenderServerControlRequestEnvelope.self)
            guard envelope.protocolVersion == SessionProtocolVersion.current
            else {
                try sendControlResult(
                    requestID: envelope.requestID,
                    result: .rejected,
                    failureCode: .invalidRequest,
                    rejection: "unsupported owner protocol version")
                return
            }
            switch envelope.request {
            case .version:
                try sendControlResult(
                    requestID: envelope.requestID,
                    result: .completed,
                    version: Self.controlVersion)
            case .outputs:
                try sendControlResult(
                    requestID: envelope.requestID,
                    result: .completed,
                    outputs: attachedControlOutputs())
            case .activeBindings:
                try sendControlResult(
                    requestID: envelope.requestID,
                    result: .completed,
                    activeBindings: liveConfiguration.binds)
            case .action(let action):
                performControlAction(action)
                try sendControlResult(
                    requestID: envelope.requestID,
                    result: .completed)
            }
        } catch {
            logRuntime("control service request failed")
        }
    }

    private static var controlVersion: String {
        "nucleus-render-server 1"
    }

    private func attachedControlOutputs() -> [RenderServerOutputSnapshot] {
        server.layout.displays.map { display in
            RenderServerOutputSnapshot(
                id: display.id,
                name: display.name,
                width: UInt32(
                    max(
                        0, Int(display.logicalRect.width.rounded()))),
                height: UInt32(
                    max(
                        0, Int(display.logicalRect.height.rounded()))),
                refreshMillihertz: Self.millihertz(
                    fromIntervalNs: display.displayLink.refreshIntervalNs),
                scale: display.fractionalScale,
                x: Int32(display.logicalRect.x.rounded()),
                y: Int32(display.logicalRect.y.rounded()),
                enabled: true)
        }
    }

    static func millihertz(fromIntervalNs interval: UInt64) -> UInt32 {
        guard interval > 0 else { return 0 }
        let value = 1_000_000_000_000 / interval
        return UInt32(min(value, UInt64(UInt32.max)))
    }

    private func performControlAction(_ action: BindAction) {
        if action.runtimeOwner == .shell,
            action != .showWindowMenu
        {
            publishControlShellAction(action)
            return
        }
        switch policyServices.bindings.perform(action) {
        case .pass, .consume:
            break
        case .deferred(let deferred):
            waylandRuntime.executeDeferredAction(
                kind: deferred.kind.rawValue,
                configurationIndex: deferred.configurationIndex,
                value: deferred.value)
            frameDemand.requestFrame()
        }
    }

    private func sendControlResult(
        requestID: OwnerControlRequestID,
        result: OwnerControlResult,
        version: String? = nil,
        outputs: [RenderServerOutputSnapshot]? = nil,
        activeBindings: [KeyBind]? = nil,
        failureCode: OwnerControlFailureCode? = nil,
        rejection: String? = nil
    ) throws {
        try controlChannel.send(
            RenderServerControlPublication(
                requestID: requestID,
                result: result,
                ownerEpoch: controlEpoch,
                configurationEpoch: configurationEpoch,
                appliedConfigurationGeneration: configurationGeneration,
                version: version,
                outputs: outputs,
                activeBindings: activeBindings,
                failureCode: failureCode,
                rejection: rejection))
    }
}
