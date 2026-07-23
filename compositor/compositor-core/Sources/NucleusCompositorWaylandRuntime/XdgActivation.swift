// xdg-activation-v1 on the router — cross-app focus handoff. The manager mints an
// activation token; the client sets its provenance (serial/seat/app-id/surface),
// commits, and receives an opaque token string; another client (or the same) calls
// activate(token, surface) to request the compositor raise/focus that surface.
//
// Tokens are one-shot grants backed by an exact input serial from this seat.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

protocol XdgActivationDelegate: AnyObject {
    /// Request focus after the manager has consumed a valid one-shot grant.
    func activateSurface(_ surface: WlSurface?, token: String)
}

final class XdgActivationBinding {
    unowned let manager: XdgActivationManager
    init(_ manager: XdgActivationManager) { self.manager = manager }
}

final class XdgActivationManager {
    weak var delegate: (any XdgActivationDelegate)?
    weak var seat: WlSeat?
    private let tokenGenerator: () -> String
    private var grants: [String: Bool] = [:]
    private var grantOrder: [String] = []

    init(tokenGenerator: (() -> String)? = nil) {
        self.tokenGenerator = tokenGenerator ?? Self.randomToken
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_xdg_activation_v1(), version: 1, impl: self, bind: Self.bind)
    }

    func mintToken(authorized: Bool) -> String {
        while true {
            let token = tokenGenerator()
            guard grants[token] == nil else { continue }
            grants[token] = authorized
            grantOrder.append(token)
            while grantOrder.count > 256 {
                grants[grantOrder.removeFirst()] = nil
            }
            return token
        }
    }

    func consumeToken(_ token: String) -> Bool {
        guard let authorized = grants.removeValue(forKey: token) else {
            return false
        }
        grantOrder.removeAll { $0 == token }
        return authorized
    }

    /// A fixed-width 128-bit token from the standard library's operating-system
    /// CSPRNG. Hex keeps the Wayland string free of escaping and encoding rules.
    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return hex(generator.next()) + hex(generator.next())
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
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
        let token = token.map { String(cString: $0) } ?? ""
        guard surface != nil, manager.consumeToken(token) else { return }
        manager.delegate?.activateSurface(surface, token: token)
    }
}

/// An activation token accumulates provenance until its one commit.
final class XdgActivationToken {
    private unowned let manager: XdgActivationManager
    private var used = false
    private var serial: UInt32?
    private weak var seat: WlSeat?
    private weak var surface: WlSurface?
    private var appID: String?

    init(manager: XdgActivationManager) { self.manager = manager }
}

extension XdgActivationToken: XdgActivationTokenV1Requests {
    func setSerial(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32,
                   seat: UnsafeMutablePointer<wl_resource>?) {
        guard !used else {
            postAlreadyUsed(resource)
            return
        }
        self.serial = serial
        self.seat = seat.flatMap {
            WaylandResource.owner(of: $0, as: SeatBinding.self)?.seat
        }
    }

    func setAppId(_ resource: UnsafeMutablePointer<wl_resource>, app_id: UnsafePointer<CChar>?) {
        guard !used else {
            postAlreadyUsed(resource)
            return
        }
        appID = app_id.map(String.init(cString:))
    }

    func setSurface(_ resource: UnsafeMutablePointer<wl_resource>,
                    surface: UnsafeMutablePointer<wl_resource>?) {
        guard !used else {
            postAlreadyUsed(resource)
            return
        }
        self.surface = surface.flatMap {
            WaylandResource.owner(of: $0, as: WlSurface.self)
        }
    }

    func commit(_ resource: UnsafeMutablePointer<wl_resource>) {
        // The token resource carries the done event; the manager mints the string.
        guard !used else {
            postAlreadyUsed(resource)
            return
        }
        used = true
        let authorized: Bool
        if let serial, let seat, let managerSeat = manager.seat,
            seat === managerSeat, let surface,
            let surfaceResource = surface.resource,
            let client = wl_resource_get_client(surfaceResource)
        {
            authorized = seat.authorize(
                serial: serial,
                clientKey: WlSeat.clientKey(client),
                surfaceID: surface.objectId,
                kinds: [.pointerButton, .touchDown, .keyboardKey])
        } else {
            authorized = false
        }
        _ = appID
        let tok = manager.mintToken(authorized: authorized)
        tok.withCString { xdg_activation_token_v1_send_done(resource, $0) }
    }

    private func postAlreadyUsed(
        _ resource: UnsafeMutablePointer<wl_resource>
    ) {
        swift_wayland_resource_post_error(
            resource, 0 /* already_used */,
            "activation token already committed")
    }
}
