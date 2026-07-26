// xdg-decoration-unstable-v1 on the router — server/client-side decoration
// negotiation. The manager mints a per-toplevel decoration object; the delegate
// resolves the effective mode from the client's request and the compositor default
// (server-side). Mode events are emitted immediately before the corresponding
// xdg_toplevel/xdg_surface configure cycle so the client applies the decoration
// choice atomically with the window state.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes

/// mode enum: client_side=1, server_side=2.
@MainActor
protocol DecorationDelegate: AnyObject {
    /// The effective mode for a toplevel, given the client's explicit request (nil =
    /// none). Default is server-side.
    func resolveDecorationMode(for toplevel: XdgToplevel?, clientRequested: UInt32?) -> UInt32
}

extension XdgDecorationManager: ZxdgDecorationManagerV1Requests {
    func getToplevelDecoration(
        _ request: WaylandRequest<ZxdgDecorationManagerV1Server>,
        id: WlNewId<ZxdgToplevelDecorationV1Server>,
        toplevel toplevelRes: WaylandBorrowedObject<XdgToplevelServer>
    ) {
        guard let toplevel = toplevelRes.owner(as: XdgToplevel.self) else { return }
        guard toplevel.decoration == nil else {
            request.postToplevelDecorationAlreadyConstructedError(
                message: "xdg_toplevel already has a decoration object")
            return
        }
        _ = id.create(
            owner: { handle in
                XdgToplevelDecoration(
                    resource: handle,
                    manager: self,
                    toplevel: toplevel)
            },
            installed: { decoration in
                toplevel.decoration = decoration
                if toplevel.xdgSurface?.hasSentInitialConfigure == true {
                    toplevel.xdgSurface?.configureToplevel(initial: false)
                }
            })
    }
}

@MainActor
@safe final class XdgDecorationManager {
    weak var delegate: (any DecorationDelegate)?

}

@MainActor
@safe final class XdgToplevelDecoration {
    private unowned let manager: XdgDecorationManager
    private weak var toplevel: XdgToplevel?
    private let resource:
        WaylandResourceHandle<ZxdgToplevelDecorationV1Server>
    private var clientRequested: UInt32?
    private var lastSent: UInt32?

    init(
        resource: WaylandResourceHandle<ZxdgToplevelDecorationV1Server>,
        manager: XdgDecorationManager,
        toplevel: XdgToplevel?
    ) {
        self.resource = resource
        self.manager = manager
        self.toplevel = toplevel
    }

    /// Resolve the effective mode and emit configure(mode) if it changed. Called
    /// from XdgSurface immediately before the rest of the configure cycle.
    func sendConfigureIfNeeded() {
        let mode = manager.delegate?.resolveDecorationMode(for: toplevel, clientRequested: clientRequested)
            ?? (clientRequested ?? 2)
        guard mode != lastSent else { return }
        lastSent = mode
        resource.sendConfigure(
            mode: ZxdgToplevelDecorationV1Mode(rawValue: mode))
    }

    private func requestConfigureCycleIfReady() {
        guard let xdgSurface = toplevel?.xdgSurface,
            xdgSurface.hasSentInitialConfigure
        else { return }
        xdgSurface.configureToplevel(initial: false)
    }

}

extension XdgToplevelDecoration: ZxdgToplevelDecorationV1Requests {
    func setMode(_ request: WaylandRequest<ZxdgToplevelDecorationV1Server>, mode: ZxdgToplevelDecorationV1Mode) {
        guard mode == .clientSide || mode == .serverSide else {
            request.postError(.unconfiguredBuffer, message: "invalid decoration mode")
            return
        }
        clientRequested = mode.rawValue
        requestConfigureCycleIfReady()
    }

    func unsetMode(_ request: WaylandRequest<ZxdgToplevelDecorationV1Server>) {
        clientRequested = nil
        requestConfigureCycleIfReady()
    }
}
