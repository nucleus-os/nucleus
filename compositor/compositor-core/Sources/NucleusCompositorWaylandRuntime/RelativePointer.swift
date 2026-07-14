// zwp_relative_pointer_v1 on the router. Delivers raw / unaccelerated pointer
// deltas (FPS games, VM clients, CAD) in parallel with wl_pointer.motion. The
// manager hands out zwp_relative_pointer_v1 objects bound to a client's pointer;
// while that pointer has focus, every motion event also emits relative_motion.
//
// The wl_pointer argument
// is never dereferenced — a relative-pointer binding delivers to its client, and
// the seat's pointerMotion path calls emitRelativeMotion for that client (wired at
// #12). libwayland owns the resource mechanics; this owns the delivery semantics.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// Owner bound to each zwp_relative_pointer_manager_v1 resource (Rule 9).
final class RelativePointerManagerBinding {
    unowned let manager: RelativePointerManager
    init(_ manager: RelativePointerManager) { self.manager = manager }
}

/// Non-owning handle to a live relative-pointer binding (the binding is owned by
/// its wl_resource).
private final class WeakRelativePointer {
    weak var binding: RelativePointer?
    init(_ binding: RelativePointer) { self.binding = binding }
}

final class RelativePointerManager {
    // zwp_relative_pointer_v1 is destroy-only (no generated dispatch): keep its
    // hand-wired vtable. fileprivate so the manager binding can pass it to id.create.
    fileprivate let pointerVtable: UnsafeMutableRawPointer
    private var bindings: [WeakRelativePointer] = []

    init() {
        pointerVtable = allocVtable(
            MemoryLayout<swift_wayland_zwp_relative_pointer_v1_requests>.stride,
            MemoryLayout<swift_wayland_zwp_relative_pointer_v1_requests>.alignment)
        let pvt = pointerVtable.bindMemory(to: swift_wayland_zwp_relative_pointer_v1_requests.self, capacity: 1)
        pvt.pointee.destroy = Self.pointerDestroy
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zwp_relative_pointer_manager_v1(), version: 1,
            impl: self, bind: Self.bind
        )
    }

    fileprivate func add(_ binding: RelativePointer) { bindings.append(WeakRelativePointer(binding)) }

    fileprivate func remove(_ binding: RelativePointer) {
        bindings.removeAll { $0.binding == nil || $0.binding === binding }
    }

    /// Emit relative_motion to every relative-pointer object of `clientKey`, in
    /// parallel with the absolute motion delivery (the protocol mandates both flow).
    /// Timestamp is microseconds; deltas are surface-local doubles.
    func emitRelativeMotion(
        clientKey key: UInt, timestampUs: UInt64,
        dx: Double, dy: Double, dxUnaccel: Double, dyUnaccel: Double
    ) {
        var live: [WeakRelativePointer] = []
        for box in bindings {
            guard let b = box.binding else { continue }
            live.append(box)
            guard b.clientKey == key, let res = b.resource else { continue }
            zwp_relative_pointer_v1_send_relative_motion(
                res,
                UInt32(timestampUs >> 32), UInt32(timestampUs & 0xffff_ffff),
                swift_wayland_fixed_from_double(dx), swift_wayland_fixed_from_double(dy),
                swift_wayland_fixed_from_double(dxUnaccel), swift_wayland_fixed_from_double(dyUnaccel)
            )
        }
        bindings = live
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: RelativePointerManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zwp_relative_pointer_manager_v1(),
            version: Int32(version), id: id, vtable: ZwpRelativePointerManagerV1Server.vtable,
            owner: RelativePointerManagerBinding(me)
        )
    }

    private static let pointerDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    deinit {
        pointerVtable.deallocate()
    }
}

// get_relative_pointer(id, pointer): the pointer is validated by libwayland's own
// interface-typed argument unmarshalling and never dereferenced here. The minted
// zwp_relative_pointer_v1 is destroy-only, so it keeps the hand-wired pointerVtable.
extension RelativePointerManagerBinding: ZwpRelativePointerManagerV1Requests {
    func getRelativePointer(
        _ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
        pointer: UnsafeMutablePointer<wl_resource>?
    ) {
        let me = manager
        let owner = RelativePointer(manager: me, client: id.client)
        guard let pres = id.create(
            vtable: UnsafeRawPointer(me.pointerVtable), owner: owner
        ) else { return }
        owner.bind(pres)
        me.add(owner)
    }
}

/// zwp_relative_pointer_v1 resource owner (Rule 9). Bound to the client; drops out
/// of the manager's delivery list on destruction.
final class RelativePointer {
    private weak var manager: RelativePointerManager?
    let clientKey: UInt
    fileprivate(set) var resource: UnsafeMutablePointer<wl_resource>?

    init(manager: RelativePointerManager, client: OpaquePointer) {
        self.manager = manager
        self.clientKey = WlSeat.clientKey(client)
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }
    deinit { manager?.remove(self) }
}
