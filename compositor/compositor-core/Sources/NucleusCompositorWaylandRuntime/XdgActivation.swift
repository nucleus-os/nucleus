// xdg-activation-v1 on the router — cross-app focus handoff. The manager mints an
// activation token; the client sets its provenance (serial/seat/app-id/surface),
// commits, and receives an opaque token string; another client (or the same) calls
// activate(token, surface) to request the compositor raise/focus that surface.
//
// Tokens are one-shot grants backed by an exact input serial from this seat.

import WaylandProtocolTypes
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

@MainActor
protocol XdgActivationDelegate: AnyObject {
    /// Request focus after the manager has consumed a valid one-shot grant.
    func activateSurface(_ surface: WlSurface?, token: String)
}

@MainActor
@safe final class XdgActivationManager {
    weak var delegate: (any XdgActivationDelegate)?
    weak var seat: WlSeat?
    private let tokenGenerator: () -> String
    private var grants: [String: Bool] = [:]
    private var grantOrder: [String] = []

    init(tokenGenerator: (() -> String)? = nil) {
        self.tokenGenerator = tokenGenerator ?? Self.randomToken
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

}

extension XdgActivationManager: XdgActivationV1Requests {
    func getActivationToken(
        _ request: WaylandRequest<XdgActivationV1Server>,
        id: WlNewId<XdgActivationTokenV1Server>
    ) {
        _ = id.create { handle in
            XdgActivationToken(resource: handle, manager: self)
        }
    }

    func activate(
        _ request: WaylandRequest<XdgActivationV1Server>, token: String,
        surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        let surface = surfaceRes.owner(as: WlSurface.self)
        guard surface != nil, consumeToken(token) else { return }
        delegate?.activateSurface(surface, token: token)
    }
}

/// An activation token accumulates provenance until its one commit.
@MainActor
@safe final class XdgActivationToken {
    private let resource: WaylandResourceHandle<XdgActivationTokenV1Server>
    private unowned let manager: XdgActivationManager
    private var used = false
    private var serial: UInt32?
    private weak var seat: WlSeat?
    private weak var surface: WlSurface?
    private var appID: String?

    init(
        resource: WaylandResourceHandle<XdgActivationTokenV1Server>,
        manager: XdgActivationManager
    ) {
        self.resource = resource
        self.manager = manager
    }
}

extension XdgActivationToken: XdgActivationTokenV1Requests {
    func setSerial(
        _ request: WaylandRequest<XdgActivationTokenV1Server>, serial: UInt32,
        seat: WaylandBorrowedObject<WlSeatServer>
    ) {
        guard !used else {
            postAlreadyUsed(request)
            return
        }
        self.serial = serial
        self.seat = seat.owner(as: SeatBinding.self)?.seat
    }

    func setAppId(_ request: WaylandRequest<XdgActivationTokenV1Server>, app_id: String) {
        guard !used else {
            postAlreadyUsed(request)
            return
        }
        appID = app_id
    }

    func setSurface(
        _ request: WaylandRequest<XdgActivationTokenV1Server>,
        surface: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard !used else {
            postAlreadyUsed(request)
            return
        }
        self.surface = surface.owner(as: WlSurface.self)
    }

    func commit(_ request: WaylandRequest<XdgActivationTokenV1Server>) {
        // The token resource carries the done event; the manager mints the string.
        guard !used else {
            postAlreadyUsed(request)
            return
        }
        used = true
        let authorized: Bool
        if let serial, let seat, let managerSeat = manager.seat,
            seat === managerSeat, let surface,
            let clientID = surface.protocolResource?.clientID
        {
            authorized = seat.authorize(
                serial: serial,
                clientKey: clientID,
                surfaceID: surface.objectId,
                kinds: [.pointerButton, .touchDown, .keyboardKey])
        } else {
            authorized = false
        }
        _ = appID
        let tok = manager.mintToken(authorized: authorized)
        resource.sendDone(token: tok)
    }

    private func postAlreadyUsed(
        _ request: WaylandRequest<XdgActivationTokenV1Server>
    ) {
        request.postError(.alreadyUsed, message: "activation token already committed")
    }
}
