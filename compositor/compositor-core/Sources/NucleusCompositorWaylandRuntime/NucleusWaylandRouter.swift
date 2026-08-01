// It owns the wl_display/event-loop through WaylandDisplay and a lifetime-managed
// registry of globals; each protocol plugs in by registering a global whose
// The shared generated-global binder recovers per-protocol state through userdata.
// Binds reach Swift through libwayland's own vtables directly.

import WaylandServer
import WaylandServerC

@MainActor
final class NucleusWaylandRouter {
    /// An independently removable global registration. The handle borrows the
    /// router so retaining it from a protocol implementation cannot form a cycle.
    @MainActor
    final class GlobalHandle {
        private weak var router: NucleusWaylandRouter?
        private let registrationID: ObjectIdentifier
        private var removed = false

        fileprivate init(
            router: NucleusWaylandRouter,
            registration: AnyObject
        ) {
            self.router = router
            self.registrationID = ObjectIdentifier(registration)
        }

        func remove() {
            guard !removed else { return }
            removed = true
            router?.removeGlobal(registrationID)
        }
    }

    let display: WaylandDisplay
    private var registrations: [WaylandGlobalRegistration] = []

    /// The wl_compositor impl, which owns the live-surface registry used for exact
    /// submitted-frame correlation. Borrowed — its registration owns the retain.
    weak var compositor: WlCompositor?

    init?() {
        guard let display = WaylandDisplay() else { return nil }
        self.display = display
    }

    @discardableResult
    func addGlobal<Interface: WaylandServerInterface>(
        _ specification: WaylandGlobalSpecification<Interface>
    ) -> GlobalHandle? {
        guard
            let registration = WaylandGlobalRegistration(
                display: display,
                specification: specification)
        else { return nil }
        registrations.append(registration)
        return GlobalHandle(router: self, registration: registration)
    }

    private func removeGlobal(_ registrationID: ObjectIdentifier) {
        registrations.removeAll {
            ObjectIdentifier($0) == registrationID
        }
    }

    // Reactor surface: the single aggregate FD the io_uring reactor watches; on
    // readiness it dispatches all ready work and flushes queued events.
    var eventLoopFd: Int32 { display.eventLoopFd }
    func dispatch() { display.dispatch() }
    func flushClients() { display.flushClients() }

    isolated deinit {
        // Destroy globals before the display. wl_display_destroy frees every
        // remaining global itself, so releasing the WaylandGlobal wrappers
        // afterwards would wl_global_destroy freed memory. Running this in the
        // deinit body guarantees the display (a stored property, released only
        // after the body) is still alive here.
        registrations.removeAll()
    }
}
