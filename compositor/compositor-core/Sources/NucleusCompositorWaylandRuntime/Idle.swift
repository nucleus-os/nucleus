// Idle protocols on the router, owned by one IdleManager:
//   - zwp_idle_inhibit_manager_v1: a client creates an inhibitor bound to a
//     surface to keep the session awake while that surface is shown. The router
//     tracks a live inhibitor count and gates regular idle notifications on it.
//   - ext_idle_notifier_v1: a client asks to be told when the seat has been idle
//     for a timeout. The router owns the notification registry and the idled/
//     resumed event delivery; the reactor's monotonic timer drives it (idleTick /
//     noteUserInput), computing deadlines from nextDeadlineMs.
//
// The clock is parameterized (timestamps passed
// in) so the mechanism is reactor-independent and directly testable. Regular
// notifications are suppressed while any inhibitor is live; input-only
// notifications (get_input_idle_notification, v2) ignore inhibitors.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

@MainActor
@safe final class IdleManager {
    /// Number of live idle inhibitors. The compositor pauses idle while > 0.
    private(set) var inhibitorCount = 0
    /// Last user-input time (ms, monotonic). Notification deadlines are relative.
    private var lastInputMs: UInt64 = 0
    private var notifications: [WeakReference<ExtIdleNotification>] = []

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            ZwpIdleInhibitManagerV1Server.global(
                implementation: self,
                owner: { manager, _ in manager }))
        router.addGlobal(
            ExtIdleNotifierV1Server.global(
                implementation: self,
                advertisedVersion: 2,
                owner: { manager, _ in manager }))
    }

    // MARK: compositor / reactor seam

    /// Earliest deadline (ms) across notifications that can still fire, or nil if
    /// none are armed. Regular notifications are excluded while inhibited.
    var nextDeadlineMs: UInt64? {
        var best: UInt64?
        for box in notifications {
            guard let n = box.value, !n.idled else { continue }
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
        for box in notifications where box.value?.idled == true {
            box.value?.sendResumed()
        }
    }

    /// Advance the idle clock to `nowMs`: fire `idled` for notifications whose
    /// deadline has elapsed and that are not suppressed by an inhibitor.
    func idleTick(nowMs: UInt64) {
        for box in notifications {
            guard let n = box.value, !n.idled else { continue }
            if !n.inputOnly, inhibitorCount > 0 { continue }
            if nowMs >= lastInputMs + UInt64(n.timeoutMs) { n.sendIdled() }
        }
    }

    // MARK: inhibitor bookkeeping

    fileprivate func addInhibitor() {
        inhibitorCount += 1
    }
    fileprivate func removeInhibitor() {
        if inhibitorCount > 0 { inhibitorCount -= 1 }
    }
    fileprivate func addNotification(_ n: ExtIdleNotification) {
        notifications.append(WeakReference(n))
    }
    fileprivate func removeNotification(_ n: ExtIdleNotification) {
        notifications.removeAll { $0.value == nil || $0.value === n }
    }

    // The inhibitor and notification children use generated destroy-only dispatch.
    fileprivate func makeNotification(
        id: WlNewId<ExtIdleNotificationV1Server>,
        timeout: UInt32,
        inputOnly: Bool
    ) {
        _ = unsafe id.create(
            owner: { handle in
                ExtIdleNotification(
                    resource: handle,
                    manager: self,
                    timeoutMs: timeout,
                    inputOnly: inputOnly)
            },
            installed: { notification in
                self.addNotification(notification)
            })
    }
}

extension IdleManager: ZwpIdleInhibitManagerV1Requests {
    // Both the inhibit-manager and notifier protocols default `destroy`; conforming to both makes the
    // default ambiguous, so pin it explicitly (plain teardown — the manager outlives its resources).
    func destroy(_ request: WaylandRequest<ZwpIdleInhibitManagerV1Server>) {
        let resource = unsafe request.resource
        unsafe wl_resource_destroy(resource)
    }

    // create_inhibitor(id, surface)
    func createInhibitor(
        _ request: WaylandRequest<ZwpIdleInhibitManagerV1Server>,
        id: WlNewId<ZwpIdleInhibitorV1Server>,
                         surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>) {
        let surface = surfaceRes.owner(as: WlSurface.self)
        _ = unsafe id.create(
            owner: { handle in
                IdleInhibitor(
                    resource: handle, manager: self, surface: surface)
            },
            installed: { _ in
                self.addInhibitor()
            })
    }
}

extension IdleManager: ExtIdleNotifierV1Requests {
    func getIdleNotification(
        _ request: WaylandRequest<ExtIdleNotifierV1Server>,
        id: WlNewId<ExtIdleNotificationV1Server>,
                             timeout: UInt32, seat: WaylandBorrowedObject<WlSeatServer>) {
        unsafe makeNotification(id: id, timeout: timeout, inputOnly: false)
    }
    func getInputIdleNotification(
        _ request: WaylandRequest<ExtIdleNotifierV1Server>,
        id: WlNewId<ExtIdleNotificationV1Server>,
                                  timeout: UInt32, seat: WaylandBorrowedObject<WlSeatServer>) {
        unsafe makeNotification(id: id, timeout: timeout, inputOnly: true)
    }
}

/// zwp_idle_inhibitor_v1 owner (Rule 9). Contributes to the inhibitor count while
/// alive; the surface association keeps the inhibition scoped to its owner.
@MainActor
final class IdleInhibitor {
    private let resource:
        WaylandResourceHandle<ZwpIdleInhibitorV1Server>
    private weak var manager: IdleManager?
    private weak var surface: WlSurface?

    init(
        resource: WaylandResourceHandle<ZwpIdleInhibitorV1Server>,
        manager: IdleManager,
        surface: WlSurface?
    ) {
        self.resource = resource
        self.manager = manager
        self.surface = surface
    }

    isolated deinit { manager?.removeInhibitor() }
}

/// ext_idle_notification_v1 owner (Rule 9). Sends idled/resumed (each guarded so
/// the protocol's "no two idled without a resumed" invariant holds).
@MainActor
@safe final class ExtIdleNotification {
    private weak var manager: IdleManager?
    let timeoutMs: UInt32
    let inputOnly: Bool
    private(set) var idled = false
    private let resource:
        WaylandResourceHandle<ExtIdleNotificationV1Server>

    init(
        resource: WaylandResourceHandle<ExtIdleNotificationV1Server>,
        manager: IdleManager,
        timeoutMs: UInt32,
        inputOnly: Bool
    ) {
        self.resource = resource
        self.manager = manager
        self.timeoutMs = timeoutMs
        self.inputOnly = inputOnly
    }
    func sendIdled() {
        guard !idled else { return }
        idled = true
        resource.sendIdled()
    }
    func sendResumed() {
        guard idled else { return }
        idled = false
        resource.sendResumed()
    }

    isolated deinit { manager?.removeNotification(self) }
}
