import NucleusReactFabricSmokeC

@MainActor
private final class CommandHandlerActorProbe {
    var received: (command: String, argsJson: String)?
}

@MainActor
private enum CommandHandlerActorSmokeState {
    static var activeProbe: CommandHandlerActorProbe?
}

@c @implementation
public func nucleus_rn_command_handler_actor_smoke_start(
    _ hbcPath: UnsafePointer<CChar>?
) -> Int32 {
    guard let hbcPath else { return 2 }
    let hbcPathValue = String(cString: hbcPath)

    return MainActor.assumeIsolated { () -> Int32 in
        guard CommandHandlerActorSmokeState.activeProbe == nil else {
            return 1
        }
        let probe = CommandHandlerActorProbe()
        CommandHandlerActorSmokeState.activeProbe = probe
        let box = CommandHandlerBox { command, argsJson in
            probe.received = (command, argsJson)
        }
        let result = hbcPathValue.withCString { ownedHBCPath in
            nucleus_rn_invoke_host_command_on_js_worker(
                CommandHandlerBox.callback,
                Unmanaged.passRetained(box).toOpaque(),
                CommandHandlerBox.release,
                ownedHBCPath)
        }
        guard result == 0 else {
            CommandHandlerActorSmokeState.activeProbe = nil
            return 100 + result
        }
        return 0
    }
}

@c @implementation
public func nucleus_rn_command_handler_actor_smoke_status() -> Int32 {
    MainActor.assumeIsolated {
        guard let probe = CommandHandlerActorSmokeState.activeProbe else {
            return -1
        }
        guard let received = probe.received else {
            return 0
        }
        return received.command == "activate"
            && received.argsJson == #"{"window":7}"#
            ? 1
            : 2
    }
}

@c @implementation
public func nucleus_rn_command_handler_actor_smoke_reset() {
    MainActor.assumeIsolated {
        CommandHandlerActorSmokeState.activeProbe = nil
    }
}
