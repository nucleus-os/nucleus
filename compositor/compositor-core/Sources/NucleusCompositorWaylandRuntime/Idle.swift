// Idle protocols on the router, owned by one IdleManager:
//   - zwp_idle_inhibit_manager_v1: a client creates an inhibitor bound to a
//     surface to keep the session awake while that surface is shown. The router
//     tracks a live inhibitor count; the compositor (at #12) gates its idle timer
//     on it.
//   - ext_idle_notifier_v1: a client asks to be told when the seat has been idle
//     for a timeout. The router owns the notification registry and the idled/
//     resumed event delivery; the reactor's monotonic timer drives it (idleTick /
//     noteUserInput) at #12, computing deadlines from nextDeadlineMs.
//
// The clock is parameterized (timestamps passed
// in) so the mechanism is reactor-independent and directly testable. Regular
// notifications are suppressed while any inhibitor is live; input-only
// notifications (get_input_idle_notification, v2) ignore inhibitors.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// The reactor seam: the router calls this when the idle schedule changes so the
/// compositor can recompute its monotonic idle timer (wired at #12).
protocol IdleDelegate: AnyObject {
    func idleScheduleChanged()
}
extension IdleDelegate {
    func idleScheduleChanged() {}
}

private final class WeakNotification {
    weak var notification: ExtIdleNotification?
    init(_ notification: ExtIdleNotification) { self.notification = notification }
}

final class IdleManager {
    weak var delegate: IdleDelegate?

    /// Destroy-only child vtable kept hand-wired: zwp_idle_inhibitor_v1 has no
    /// non-destructor request, so it has no generated dispatch.
    private let inhibitorVtable: UnsafeMutableRawPointer
    /// Destroy-only child vtable kept hand-wired: ext_idle_notification_v1 has no
    /// non-destructor request, so it has no generated dispatch.
    private let notificationVtable: UnsafeMutableRawPointer

    /// Number of live idle inhibitors. The compositor pauses idle while > 0.
    private(set) var inhibitorCount = 0
    /// Last user-input time (ms, monotonic). Notification deadlines are relative.
    private var lastInputMs: UInt64 = 0
    private var notifications: [WeakNotification] = []

    init() {
        inhibitorVtable = allocVtable(
            MemoryLayout<swift_wayland_zwp_idle_inhibitor_v1_requests>.stride,
            MemoryLayout<swift_wayland_zwp_idle_inhibitor_v1_requests>.alignment)
        let iv = inhibitorVtable.bindMemory(
            to: swift_wayland_zwp_idle_inhibitor_v1_requests.self, capacity: 1)
        iv.pointee.destroy = IdleInhibitor.objectDestroy

        notificationVtable = allocVtable(
            MemoryLayout<swift_wayland_ext_idle_notification_v1_requests>.stride,
            MemoryLayout<swift_wayland_ext_idle_notification_v1_requests>.alignment)
        let nnv = notificationVtable.bindMemory(
            to: swift_wayland_ext_idle_notification_v1_requests.self, capacity: 1)
        nnv.pointee.destroy = ExtIdleNotification.objectDestroy
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zwp_idle_inhibit_manager_v1(), version: 1,
            impl: self, bind: Self.bindInhibit)
        router.addGlobal(
            interface: swift_wayland_iface_ext_idle_notifier_v1(), version: 2,
            impl: self, bind: Self.bindNotifier)
    }

    // MARK: compositor / reactor seam (driven directly by fixtures, by the reactor at #12)

    /// Earliest deadline (ms) across notifications that can still fire, or nil if
    /// none are armed. Regular notifications are excluded while inhibited.
    var nextDeadlineMs: UInt64? {
        var best: UInt64?
        for box in notifications {
            guard let n = box.notification, !n.idled else { continue }
            if !n.inputOnly, inhibitorCount > 0 { continue }
            let deadline = lastInputMs + UInt64(n.timeoutMs)
            if best == nil || deadline < best! { best = deadline }
        }
        return best
    }

    /// Record user input at `atMs`: resume any idled notifications and reset the
    /// idle clock.
    func noteUserInput(atMs: UInt64) {
        lastInputMs = atMs
        for box in notifications where box.notification?.idled == true {
            box.notification?.sendResumed()
        }
        delegate?.idleScheduleChanged()
    }

    /// Advance the idle clock to `nowMs`: fire `idled` for notifications whose
    /// deadline has elapsed and that are not suppressed by an inhibitor.
    func idleTick(nowMs: UInt64) {
        for box in notifications {
            guard let n = box.notification, !n.idled else { continue }
            if !n.inputOnly, inhibitorCount > 0 { continue }
            if nowMs >= lastInputMs + UInt64(n.timeoutMs) { n.sendIdled() }
        }
    }

    // MARK: inhibitor bookkeeping

    fileprivate func addInhibitor() {
        inhibitorCount += 1
        delegate?.idleScheduleChanged()
    }
    fileprivate func removeInhibitor() {
        if inhibitorCount > 0 { inhibitorCount -= 1 }
        delegate?.idleScheduleChanged()
    }
    fileprivate func addNotification(_ n: ExtIdleNotification) {
        notifications.append(WeakNotification(n))
        delegate?.idleScheduleChanged()
    }
    fileprivate func removeNotification(_ n: ExtIdleNotification) {
        notifications.removeAll { $0.notification == nil || $0.notification === n }
        delegate?.idleScheduleChanged()
    }

    // MARK: binds

    private static let bindInhibit: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: IdleManager.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zwp_idle_inhibit_manager_v1(),
            version: Int32(version), id: id, vtable: ZwpIdleInhibitManagerV1Server.vtable, owner: me)
    }

    private static let bindNotifier: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: IdleManager.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_ext_idle_notifier_v1(),
            version: Int32(version), id: id, vtable: ExtIdleNotifierV1Server.vtable, owner: me)
    }

    // The inhibitor / notification children are destroy-only (no non-destructor
    // request), so they keep their hand-wired vtables; `id.create` materializes them
    // against `inhibitorVtable` / `notificationVtable`.
    fileprivate func makeNotification(id: WlNewId, timeout: UInt32, inputOnly: Bool) {
        let n = ExtIdleNotification(manager: self, timeoutMs: timeout, inputOnly: inputOnly)
        guard let nres = id.create(vtable: UnsafeRawPointer(notificationVtable), owner: n) else { return }
        n.bind(nres)
        addNotification(n)
    }

    deinit {
        inhibitorVtable.deallocate()
        notificationVtable.deallocate()
    }
}

extension IdleManager: ZwpIdleInhibitManagerV1Requests {
    // Both the inhibit-manager and notifier protocols default `destroy`; conforming to both makes the
    // default ambiguous, so pin it explicitly (plain teardown — the manager outlives its resources).
    func destroy(_ resource: UnsafeMutablePointer<wl_resource>) { wl_resource_destroy(resource) }

    // create_inhibitor(id, surface)
    func createInhibitor(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                         surface surfaceRes: UnsafeMutablePointer<wl_resource>?) {
        let surface = surfaceRes.flatMap { WaylandResource.owner(of: $0, as: WlSurface.self) }
        let inhibitor = IdleInhibitor(manager: self, surface: surface)
        guard id.create(vtable: UnsafeRawPointer(inhibitorVtable), owner: inhibitor) != nil
        else { return }
        addInhibitor()
    }
}

extension IdleManager: ExtIdleNotifierV1Requests {
    func getIdleNotification(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                             timeout: UInt32, seat: UnsafeMutablePointer<wl_resource>?) {
        makeNotification(id: id, timeout: timeout, inputOnly: false)
    }
    func getInputIdleNotification(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                                  timeout: UInt32, seat: UnsafeMutablePointer<wl_resource>?) {
        makeNotification(id: id, timeout: timeout, inputOnly: true)
    }
}

/// zwp_idle_inhibitor_v1 owner (Rule 9). Contributes to the inhibitor count while
/// alive; the surface is held for #12 visibility policy.
final class IdleInhibitor {
    private weak var manager: IdleManager?
    private weak var surface: WlSurface?

    init(manager: IdleManager, surface: WlSurface?) {
        self.manager = manager
        self.surface = surface
    }

    fileprivate static let objectDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    deinit { manager?.removeInhibitor() }
}

/// ext_idle_notification_v1 owner (Rule 9). Sends idled/resumed (each guarded so
/// the protocol's "no two idled without a resumed" invariant holds).
final class ExtIdleNotification {
    private weak var manager: IdleManager?
    let timeoutMs: UInt32
    let inputOnly: Bool
    private(set) var idled = false
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(manager: IdleManager, timeoutMs: UInt32, inputOnly: Bool) {
        self.manager = manager
        self.timeoutMs = timeoutMs
        self.inputOnly = inputOnly
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    func sendIdled() {
        guard let resource, !idled else { return }
        idled = true
        ext_idle_notification_v1_send_idled(resource)
    }
    func sendResumed() {
        guard let resource, idled else { return }
        idled = false
        ext_idle_notification_v1_send_resumed(resource)
    }

    fileprivate static let objectDestroy: @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<wl_resource>?
    ) -> Void = { _, resource in if let resource { wl_resource_destroy(resource) } }

    deinit { manager?.removeNotification(self) }
}
