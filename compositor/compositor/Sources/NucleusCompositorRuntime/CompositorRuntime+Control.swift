import NucleusCompositorServer
import NucleusConfig
import NucleusIPC

// Answering control requests. Every request either reads state the runtime
// already owns or routes into the same executor a key binding uses, so nothing
// here is a second implementation of anything.

extension CompositorRuntime: ControlRequestHandler {
    func handle(_ request: ControlRequest) -> ControlResponse {
        switch request {
        case .version:
            return .version(Self.version)
        case .configuration:
            return .configuration(currentConfiguration)
        case .binds:
            return .binds(currentConfiguration.binds)
        case .reloadConfiguration:
            return reloadConfigurationNow()
        case .outputs:
            return .outputs(attachedOutputs())
        case .action(let action):
            return perform(action)
        }
    }

    static var version: String {
        "nucleus \(NucleusConfiguration.currentVersion)"
    }

    /// What is in force right now — the reload coordinator's copy when there is
    /// one, since it is the thing that has been tracking changes.
    private var currentConfiguration: NucleusConfiguration {
        configReload?.current ?? .defaults
    }

    private func reloadConfigurationNow() -> ControlResponse {
        guard let coordinator = configReload else {
            return .error("configuration reload is unavailable")
        }
        let outcome = coordinator.reloadNow()
        reportConfigReload(outcome)
        if let failure = outcome.diagnostics.first(
            where: { $0.severity == .error })
        {
            return .error(failure.summary)
        }
        return .ok
    }

    private func attachedOutputs() -> [ControlOutput] {
        server.layout.displays.map { display in
            ControlOutput(
                name: display.name,
                width: UInt32(max(0, Int(display.logicalRect.width.rounded()))),
                height: UInt32(
                    max(0, Int(display.logicalRect.height.rounded()))),
                refreshMillihertz: Self.millihertz(
                    fromIntervalNs: display.displayLink.refreshIntervalNs),
                scale: display.fractionalScale,
                x: Int32(display.logicalRect.x.rounded()),
                y: Int32(display.logicalRect.y.rounded()),
                // Every display in the layout is live; a disabled output is
                // absent from it rather than present and off.
                enabled: true)
        }
    }

    /// Convert a refresh interval to millihertz.
    ///
    /// The runtime stores an interval in nanoseconds; the control protocol
    /// reports millihertz so fractional rates like 59.94 Hz survive, which an
    /// integer hertz would round away.
    static func millihertz(fromIntervalNs interval: UInt64) -> UInt32 {
        guard interval > 0 else { return 0 }
        let value = 1_000_000_000_000 / interval
        return UInt32(min(value, UInt64(UInt32.max)))
    }

    /// Route an action through the binding service, so a command performs
    /// exactly what the equivalent chord performs — including the parts that
    /// depend on keyboard focus.
    private func perform(_ action: BindAction) -> ControlResponse {
        switch shellServices.keybinds.perform(action) {
        case .pass, .consume:
            return .ok
        case .deferred(let deferred):
            waylandRuntime.executeDeferredAction(
                kind: deferred.kind, value: deferred.value)
            frameDemand.requestFrame()
            return .ok
        }
    }
}
