import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes
@testable import NucleusCompositorWaylandRuntime

// Tests advertise deliberately small protocol subsets. These adapters keep that
// test-only catalog explicit without putting registration policy back on the
// production protocol implementation types.
@MainActor
extension WlCompositor {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(WlCompositorServer.global(
            implementation: self, advertisedVersion: 6))
    }
}

@MainActor
extension XdgShell {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(XdgWmBaseServer.global(
            implementation: self,
            advertisedVersion: 3,
            owner: { shell, resource in
                XdgWmBaseBinding(shell, resource: resource)
            }))
    }
}

@MainActor
extension XdgDecorationManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(ZxdgDecorationManagerV1Server.global(
            implementation: self, advertisedVersion: 2))
    }
}

@MainActor
extension WlSeat {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(WlSeatServer.global(
            implementation: self,
            advertisedVersion: 9,
            owner: { seat, handle in
                SeatBinding(resource: handle, seat: seat)
            },
            installed: { seat, _, handle in
                seat.registerSeatResource(handle)
                if handle.supportsName {
                    handle.sendName(name: "seat0")
                }
                handle.sendCapabilities(capabilities: WlSeatCapability(
                    rawValue: seat.capabilities))
            }))
        router.addGlobal(
            ZwpKeyboardShortcutsInhibitManagerV1Server.global(
                implementation: self))
    }
}

@MainActor
extension WlDataDeviceManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(WlDataDeviceManagerServer.global(
            implementation: self, advertisedVersion: 3))
    }
}

@MainActor
extension WlOutput {
    @discardableResult
    func register(in router: NucleusWaylandRouter) -> Bool {
        installGlobal(router.addGlobal(WlOutputServer.global(
            implementation: self,
            advertisedVersion: 4,
            owner: { output, handle in
                WlOutputBinding(resource: handle, output: output)
            },
            installed: { output, _, handle in
                output.resourceInstalled(handle)
            })))
    }
}

@MainActor
extension ZwlrLayerShell {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(ZwlrLayerShellV1Server.global(
            implementation: self, advertisedVersion: 4))
    }
}

@MainActor
extension ZwlrForeignToplevelManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(ZwlrForeignToplevelManagerV1Server.global(
            implementation: self,
            advertisedVersion: 3,
            owner: { manager, handle in
                ForeignToplevelClient(resource: handle, manager: manager)
            },
            installed: { _, projection, _ in projection.start() }))
    }
}

@MainActor
extension ScreencopyManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(ZwlrScreencopyManagerV1Server.global(
            implementation: self, advertisedVersion: 3))
    }
}

@MainActor
extension ZwlrGammaControlManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(ZwlrGammaControlManagerV1Server.global(
            implementation: self))
    }
}

@MainActor
extension ZwpLinuxDmabuf {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(ZwpLinuxDmabufV1Server.global(
            implementation: self, advertisedVersion: 5))
    }
}

@MainActor
extension WpLinuxDrmSyncobjManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(WpLinuxDrmSyncobjManagerV1Server.global(
            implementation: self))
    }
}

@MainActor
extension XdgOutputManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(ZxdgOutputManagerV1Server.global(
            implementation: self, advertisedVersion: 3))
    }
}

@MainActor
extension SessionLockManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(ExtSessionLockManagerV1Server.global(
            implementation: self))
    }
}

@MainActor
extension WpPresentation {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(WpPresentationServer.global(
            implementation: self,
            advertisedVersion: 2,
            installed: { presentation, handle in
                handle.sendClockId(clk_id: presentation.clockId)
            }))
    }
}

@MainActor
extension XdgActivationManager {
    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(XdgActivationV1Server.global(
            implementation: self))
    }
}
