// xdg-activation-v1 on the router — cross-app focus handoff. The manager mints an
// activation token; the client sets its provenance (serial/seat/app-id/surface),
// commits, and receives an opaque token string; another client (or the same) calls
// activate(token, surface) to request the compositor raise/focus that surface.
//
// Token policy is permissive (every commit yields a fresh token). The actual
// raise/focus is the XdgActivationDelegate seam (#12: WindowManager).

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

protocol XdgActivationDelegate: AnyObject {
    /// Request focus for `surface` carrying `token`. The token's validity policy is
    /// the delegate's; the router is permissive.
    func activateSurface(_ surface: WlSurface?, token: String)
}

final class XdgActivationBinding {
    unowned let manager: XdgActivationManager
    init(_ manager: XdgActivationManager) { self.manager = manager }
}

final class XdgActivationManager {
    weak var delegate: XdgActivationDelegate?
    private var tokenCounter: UInt64 = 0

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_xdg_activation_v1(), version: 1, impl: self, bind: Self.bind)
    }

    func mintToken() -> String {
        tokenCounter += 1
        return "nucleus-activation-\(tokenCounter)"
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: XdgActivationManager.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_xdg_activation_v1(), version: Int32(version),
            id: id, vtable: XdgActivationV1Server.vtable, owner: XdgActivationBinding(me))
    }
}

extension XdgActivationBinding: XdgActivationV1Requests {
    func getActivationToken(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        _ = id.create(vtable: XdgActivationTokenV1Server.vtable, owner: XdgActivationToken(manager: manager))
    }

    func activate(_ resource: UnsafeMutablePointer<wl_resource>, token: UnsafePointer<CChar>?,
                  surface surfaceRes: UnsafeMutablePointer<wl_resource>?) {
        let surface = surfaceRes.flatMap { WaylandResource.owner(of: $0, as: WlSurface.self) }
        manager.delegate?.activateSurface(surface, token: token.map { String(cString: $0) } ?? "")
    }
}

/// An activation token. Provenance setters are permissive no-ops; commit emits a
/// fresh token via the done event.
final class XdgActivationToken {
    private unowned let manager: XdgActivationManager
    private var used = false

    init(manager: XdgActivationManager) { self.manager = manager }
}

extension XdgActivationToken: XdgActivationTokenV1Requests {
    func setSerial(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32,
                   seat: UnsafeMutablePointer<wl_resource>?) {}

    func setAppId(_ resource: UnsafeMutablePointer<wl_resource>, app_id: UnsafePointer<CChar>?) {}

    func setSurface(_ resource: UnsafeMutablePointer<wl_resource>,
                    surface: UnsafeMutablePointer<wl_resource>?) {}

    func commit(_ resource: UnsafeMutablePointer<wl_resource>) {
        // The token resource carries the done event; the manager mints the string.
        guard !used else {
            swift_wayland_resource_post_error(resource, 0 /* already_used */, "activation token already committed")
            return
        }
        used = true
        let tok = manager.mintToken()
        tok.withCString { xdg_activation_token_v1_send_done(resource, $0) }
    }
}
