// xdg-decoration-unstable-v1 on the router — server/client-side decoration
// negotiation. The manager mints a per-toplevel decoration object; the delegate
// resolves the effective mode from the client's request and the compositor default
// (server-side). Mode events are emitted immediately before the corresponding
// xdg_toplevel/xdg_surface configure cycle so the client applies the decoration
// choice atomically with the window state.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// mode enum: client_side=1, server_side=2.
protocol DecorationDelegate: AnyObject {
    /// The effective mode for a toplevel, given the client's explicit request (nil =
    /// none). Default is server-side.
    func resolveDecorationMode(for toplevel: XdgToplevel?, clientRequested: UInt32?) -> UInt32
}

final class XdgDecorationManagerBinding {
    unowned let manager: XdgDecorationManager
    init(_ manager: XdgDecorationManager) { self.manager = manager }
}

// The zxdg_decoration_manager_v1 request handlers, recovered by
// ZxdgDecorationManagerV1Server.vtable from the per-resource binding owner.
extension XdgDecorationManagerBinding: ZxdgDecorationManagerV1Requests {
    func getToplevelDecoration(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        toplevel toplevelRes: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let toplevelRes,
            let toplevel = WaylandResource.owner(of: toplevelRes, as: XdgToplevel.self)
        else { return }
        guard toplevel.decoration == nil else {
            swift_wayland_resource_post_error(
                resource, 0,
                "xdg_toplevel already has a decoration object")
            return
        }
        let decoration = XdgToplevelDecoration(manager: manager, toplevel: toplevel)
        guard let dres = id.create(vtable: ZxdgToplevelDecorationV1Server.vtable, owner: decoration)
        else { return }
        decoration.bind(dres)
        toplevel.decoration = decoration
        if toplevel.xdgSurface?.hasSentInitialConfigure == true {
            toplevel.xdgSurface?.configureToplevel(initial: false)
        }
    }
}

final class XdgDecorationManager {
    weak var delegate: DecorationDelegate?

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zxdg_decoration_manager_v1(), version: 2, impl: self, bind: Self.bind)
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: XdgDecorationManager.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zxdg_decoration_manager_v1(), version: Int32(version),
            id: id, vtable: ZxdgDecorationManagerV1Server.vtable, owner: XdgDecorationManagerBinding(me))
    }
}

final class XdgToplevelDecoration {
    private unowned let manager: XdgDecorationManager
    private weak var toplevel: XdgToplevel?
    private var resource: UnsafeMutablePointer<wl_resource>?
    private var clientRequested: UInt32?
    private var lastSent: UInt32?

    init(manager: XdgDecorationManager, toplevel: XdgToplevel?) {
        self.manager = manager
        self.toplevel = toplevel
    }

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Resolve the effective mode and emit configure(mode) if it changed. Called
    /// from XdgSurface immediately before the rest of the configure cycle.
    func sendConfigureIfNeeded() {
        let mode = manager.delegate?.resolveDecorationMode(for: toplevel, clientRequested: clientRequested)
            ?? (clientRequested ?? 2)
        guard mode != lastSent else { return }
        lastSent = mode
        if let resource { zxdg_toplevel_decoration_v1_send_configure(resource, mode) }
    }

    private func requestConfigureCycleIfReady() {
        guard let xdgSurface = toplevel?.xdgSurface,
            xdgSurface.hasSentInitialConfigure
        else { return }
        xdgSurface.configureToplevel(initial: false)
    }

}

extension XdgToplevelDecoration: ZxdgToplevelDecorationV1Requests {
    func setMode(_ resource: UnsafeMutablePointer<wl_resource>, mode: UInt32) {
        guard mode == 1 || mode == 2 else {
            swift_wayland_resource_post_error(
                resource, 0, "invalid decoration mode")
            return
        }
        clientRequested = mode
        requestConfigureCycleIfReady()
    }

    func unsetMode(_ resource: UnsafeMutablePointer<wl_resource>) {
        clientRequested = nil
        requestConfigureCycleIfReady()
    }
}
