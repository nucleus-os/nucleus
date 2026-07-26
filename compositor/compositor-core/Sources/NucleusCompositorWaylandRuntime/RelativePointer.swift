// zwp_relative_pointer_v1 on the router. Delivers raw / unaccelerated pointer
// deltas (FPS games, VM clients, CAD) in parallel with wl_pointer.motion. The
// manager hands out zwp_relative_pointer_v1 objects bound to a client's pointer;
// while that pointer has focus, every motion event also emits relative_motion.
//
// A relative-pointer binding retains the associated pointer owner, and the seat's
// pointerMotion path emits relative motion to the focused client's live bindings.
// libwayland owns the resource mechanics; this owns the delivery semantics.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// Non-owning handle to a live relative-pointer binding (the binding is owned by
/// its wl_resource).
@MainActor
@safe final class RelativePointerManager {
    private var bindings: [WeakReference<RelativePointer>] = []

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            ZwpRelativePointerManagerV1Server.global(
                implementation: self))
    }

    fileprivate func add(_ binding: RelativePointer) {
        bindings.append(WeakReference(binding))
    }

    fileprivate func remove(_ binding: RelativePointer) {
        bindings.removeAll { $0.value == nil || $0.value === binding }
    }

    /// Emit relative_motion to every relative-pointer object of `clientKey`, in
    /// parallel with the absolute motion delivery (the protocol mandates both flow).
    /// Timestamp is microseconds; deltas are surface-local doubles.
    func emitRelativeMotion(
        clientKey key: WaylandClientID, timestampUs: UInt64,
        dx: Double, dy: Double, dxUnaccel: Double, dyUnaccel: Double
    ) {
        var live: [WeakReference<RelativePointer>] = []
        for box in bindings {
            guard let b = box.value else { continue }
            live.append(box)
            guard b.clientKey == key else { continue }
            b.resource.sendRelativeMotion(
                utime_hi: UInt32(timestampUs >> 32),
                utime_lo: UInt32(timestampUs & 0xffff_ffff),
                dx: dx, dy: dy,
                dx_unaccel: dxUnaccel, dy_unaccel: dyUnaccel)
        }
        bindings = live
    }

}

// get_relative_pointer(id, pointer): the pointer is validated by libwayland's own
// interface-typed argument unmarshalling and never dereferenced here. The minted
// zwp_relative_pointer_v1 uses generated destroy-only dispatch.
extension RelativePointerManager: ZwpRelativePointerManagerV1Requests {
    func getRelativePointer(
        _ request: WaylandRequest<ZwpRelativePointerManagerV1Server>,
        id: WlNewId<ZwpRelativePointerV1Server>,
        pointer: WaylandBorrowedObject<WlPointerServer>
    ) {
        _ = id.create(
            owner: { handle in
                RelativePointer(
                    resource: handle, manager: self, clientKey: id.clientID)
            },
            installed: { owner in
                self.add(owner)
            })
    }
}

/// zwp_relative_pointer_v1 resource owner (Rule 9). Bound to the client; drops out
/// of the manager's delivery list on destruction.
@MainActor
@safe final class RelativePointer {
    private weak var manager: RelativePointerManager?
    let clientKey: WaylandClientID
    let resource: WaylandResourceHandle<ZwpRelativePointerV1Server>

    init(
        resource: WaylandResourceHandle<ZwpRelativePointerV1Server>,
        manager: RelativePointerManager,
        clientKey: WaylandClientID
    ) {
        self.resource = resource
        self.manager = manager
        self.clientKey = clientKey
    }
    isolated deinit { manager?.remove(self) }
}
