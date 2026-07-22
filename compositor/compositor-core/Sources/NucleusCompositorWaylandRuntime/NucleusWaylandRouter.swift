// It owns the wl_display/event-loop through WaylandDisplay and a lifetime-managed
// registry of globals; each protocol plugs in by registering a global whose
// @convention(c) bind recovers its per-protocol state through the data pointer.
// Binds reach Swift through libwayland's own vtables directly.

import WaylandServerC
import WaylandServer

final class NucleusWaylandRouter {
    fileprivate final class GlobalRegistration {
        let impl: AnyObject
        private var global: WaylandGlobal?

        init?(
            display: WaylandDisplay,
            interface: UnsafePointer<wl_interface>?,
            version: Int32,
            impl: AnyObject,
            bind: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32) -> Void
        ) {
            self.impl = impl
            let data = Unmanaged.passUnretained(impl).toOpaque()
            guard let global = WaylandGlobal(
                display: display, interface: interface, version: version, data: data, bind: bind
            ) else { return nil }
            self.global = global
        }

        deinit {
            // The data pointer borrows `impl`; destroy the global before releasing it.
            global = nil
        }
    }

    /// An independently removable global registration. The handle borrows the
    /// router so retaining it from a protocol implementation cannot form a cycle.
    final class GlobalHandle {
        private weak var router: NucleusWaylandRouter?
        private let registrationID: ObjectIdentifier
        private var removed = false

        fileprivate init(
            router: NucleusWaylandRouter,
            registration: GlobalRegistration
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
    private var registrations: [GlobalRegistration] = []

    /// The wl_compositor impl, which owns the live-surface registry used for exact
    /// submitted-frame correlation. Borrowed — its registration owns the retain.
    weak var compositor: WlCompositor?

    init?() {
        guard let display = WaylandDisplay() else { return nil }
        self.display = display
    }

    /// Register a protocol global. `impl` is retained for the router's lifetime
    /// and passed as the global's bind data, so the @convention(c) `bind` can
    /// recover it via `NucleusWaylandRouter.impl(_:as:)`.
    @discardableResult
    func addGlobal(
        interface: UnsafePointer<wl_interface>?,
        version: Int32,
        impl: AnyObject,
        bind: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32) -> Void
    ) -> GlobalHandle? {
        guard let registration = GlobalRegistration(
            display: display, interface: interface, version: version, impl: impl, bind: bind
        ) else { return nil }
        registrations.append(registration)
        return GlobalHandle(router: self, registration: registration)
    }

    private func removeGlobal(_ registrationID: ObjectIdentifier) {
        registrations.removeAll {
            ObjectIdentifier($0) == registrationID
        }
    }

    /// Recover the protocol impl a bind callback was registered with. The
    /// reference is borrowed; the router's registration owns the retain.
    static func impl<T: AnyObject>(_ data: UnsafeMutableRawPointer?, as _: T.Type) -> T? {
        guard let data else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(data).takeUnretainedValue() as? T
    }

    // Reactor surface: the single aggregate FD the io_uring reactor watches; on
    // readiness it dispatches all ready work and flushes queued events.
    var eventLoopFd: Int32 { display.eventLoopFd }
    func dispatch() { display.dispatch() }
    func flushClients() { display.flushClients() }

    deinit {
        // Destroy globals before the display. wl_display_destroy frees every
        // remaining global itself, so releasing the WaylandGlobal wrappers
        // afterwards would wl_global_destroy freed memory. Running this in the
        // deinit body guarantees the display (a stored property, released only
        // after the body) is still alive here.
        registrations.removeAll()
    }
}
