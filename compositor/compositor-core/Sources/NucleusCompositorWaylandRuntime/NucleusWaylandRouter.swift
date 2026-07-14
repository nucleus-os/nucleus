// The Swift owner of every Wayland protocol implementation (boundary Phase 4).
// It owns the wl_display/event-loop through WaylandDisplay and a lifetime-managed
// registry of globals; each protocol plugs in by registering a global whose
// @convention(c) bind recovers its per-protocol state through the data pointer.
// Binds reach Swift through libwayland's own vtables directly.

import WaylandServerC
import WaylandServer

final class NucleusWaylandRouter {
    private final class GlobalRegistration {
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

    let display: WaylandDisplay
    private var registrations: [GlobalRegistration] = []

    /// The wl_compositor impl, which owns the live-surface registry the
    /// presentation tick iterates. Borrowed — its registration owns the retain. Set when
    /// the compositor global is registered (at the cutover); nil keeps the
    /// frame/presentation completion crossings inert until then.
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
    ) -> Bool {
        guard let registration = GlobalRegistration(
            display: display, interface: interface, version: version, impl: impl, bind: bind
        ) else { return false }
        registrations.append(registration)
        return true
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

    // Presentation/frame completion seam: the render/DRM present
    // path drives these once per frame/flip, delivering wl_surface.frame and
    // wp_presentation_feedback to the router's surfaces (which own the callback +
    // feedback resources).

    /// Fire wl_surface.frame on every live surface's latched commit.
    func completeFrameCallbacksForAllSurfaces(timeMs: UInt32) {
        compositor?.present(timeMs: timeMs)
    }

    /// Fire wl_surface.frame for surfaces presented on `outputId`.
    @MainActor
    func completeFrameCallbacks(forOutput outputId: UInt64, timeMs: UInt32) {
        compositor?.present(forOutput: outputId, timeMs: timeMs)
    }

    /// Deliver wp_presentation_feedback.presented for the frame that flipped on
    /// `outputId`, splitting the 64-bit timestamp/MSC into protocol hi/lo halves.
    @MainActor
    func completePresentedFrame(
        outputId: UInt64, timestampNs: UInt64, refreshNs: UInt32,
        sequence: UInt64, flags: UInt32
    ) {
        let tvSec = timestampNs / 1_000_000_000
        let tvNsec = UInt32(timestampNs % 1_000_000_000)
        compositor?.presentFeedback(
            forOutput: outputId,
            tvSecHi: UInt32(truncatingIfNeeded: tvSec >> 32),
            tvSecLo: UInt32(truncatingIfNeeded: tvSec),
            tvNsec: tvNsec,
            refreshNs: refreshNs,
            seqHi: UInt32(truncatingIfNeeded: sequence >> 32),
            seqLo: UInt32(truncatingIfNeeded: sequence),
            flags: flags)
    }

    deinit {
        // Destroy globals before the display. wl_display_destroy frees every
        // remaining global itself, so releasing the WaylandGlobal wrappers
        // afterwards would wl_global_destroy freed memory. Running this in the
        // deinit body guarantees the display (a stored property, released only
        // after the body) is still alive here.
        registrations.removeAll()
    }
}
