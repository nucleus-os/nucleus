// xdg-decoration-unstable-v1 on the router — server/client-side decoration
// negotiation. The manager mints a per-toplevel decoration object; the delegate
// resolves the effective mode from the client's request and the compositor default
// (server-side). The resolved mode drives the window's style at #12; here the
// object owns the set_mode/unset_mode state and emits the configure(mode) event.
//
// The retired path batched the decoration configure into the toplevel's
// xdg_surface.configure cycle so the client applied it atomically. That batching is
// a #12 refinement; on the router the configure is sent when the mode resolves.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// mode enum: client_side=1, server_side=2.
protocol DecorationDelegate: AnyObject {
    /// The effective mode for a toplevel, given the client's explicit request (nil =
    /// none). Default is server-side. #12 folds in the per-window style/env policy.
    func resolveDecorationMode(for toplevel: XdgToplevel?, clientRequested: UInt32?) -> UInt32
}

extension DecorationDelegate {
    func resolveDecorationMode(for toplevel: XdgToplevel?, clientRequested: UInt32?) -> UInt32 {
        clientRequested ?? 2  // server_side default
    }
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
        let decoration = XdgToplevelDecoration(manager: manager, toplevel: toplevel)
        guard let dres = id.create(vtable: ZxdgToplevelDecorationV1Server.vtable, owner: decoration)
        else { return }
        decoration.bind(dres)
        // Advertise the resolved mode immediately (the initial configure).
        decoration.applyAndConfigure()
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

    /// Resolve the effective mode and emit configure(mode) if it changed.
    fileprivate func applyAndConfigure() {
        let mode = manager.delegate?.resolveDecorationMode(for: toplevel, clientRequested: clientRequested)
            ?? (clientRequested ?? 2)
        guard mode != lastSent else { return }
        lastSent = mode
        if let resource { zxdg_toplevel_decoration_v1_send_configure(resource, mode) }
    }

}

extension XdgToplevelDecoration: ZxdgToplevelDecorationV1Requests {
    func setMode(_ resource: UnsafeMutablePointer<wl_resource>, mode: UInt32) {
        clientRequested = mode
        applyAndConfigure()
    }

    func unsetMode(_ resource: UnsafeMutablePointer<wl_resource>) {
        clientRequested = nil
        applyAndConfigure()
    }
}
