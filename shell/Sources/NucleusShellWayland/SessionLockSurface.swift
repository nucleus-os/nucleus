// One `ext_session_lock_surface_v1` — the lock role assigned to a wl_surface, one
// per output for the duration of the lock.
//
// The configure handshake is mandatory and stricter than layer-shell's: the
// protocol requires the client to ack every configure and to attach a buffer of
// exactly the configured size. Committing a wrongly-sized buffer is a protocol
// error that kills the client — and a killed locker leaves the compositor
// holding a blank fail-closed session, so getting this wrong is not a cosmetic
// bug.

import WaylandClientC
public import WaylandClientDispatch

@MainActor
public final class SessionLockSurface {
    public let wlSurface: OpaquePointer
    public let lockSurface: OpaquePointer
    public let output: WaylandOutput

    /// The size the compositor requires this surface to be. Authoritative: a
    /// lock surface does not get to pick its own size.
    public private(set) var configuredWidth: UInt32 = 0
    public private(set) var configuredHeight: UInt32 = 0
    public private(set) var hasConfigure = false

    /// Fired on each configure with the required size. The render backend sizes
    /// its swapchain to exactly this and presents.
    public var onConfigure: ((UInt32, UInt32) -> Void)?
    private var isDestroyed = false

    public init?(lock: OpaquePointer, client: ShellWaylandClient, output: WaylandOutput) {
        guard let surface = client.createSurface() else { return nil }
        guard let lockSurface = ext_session_lock_v1_get_lock_surface(
            lock, surface, output.proxy)
        else {
            wl_surface_destroy(surface)
            return nil
        }
        self.wlSurface = surface
        self.lockSurface = lockSurface
        self.output = output
        ExtSessionLockSurfaceV1Client.addListener(lockSurface, owner: self)
        // No commit here: unlike layer-shell, the compositor sends the first
        // configure unprompted, and committing a bufferless surface first is
        // not part of this protocol's handshake.
    }

    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        ext_session_lock_surface_v1_destroy(lockSurface)
        wl_surface_destroy(wlSurface)
    }

    isolated deinit {
        destroy()
    }
}

// The generated event dispatch is nonisolated (a @convention(c) libwayland
// callback); the shell pumps wl_display on its main-thread event loop, so each
// handler reasserts the main actor.
extension SessionLockSurface: ExtSessionLockSurfaceV1Events {
    public nonisolated func configure(
        _ proxy: OpaquePointer, serial: UInt32, width: UInt32, height: UInt32
    ) {
        // Acked before the actor hop, as layer-shell does: it is a C call on the
        // proxy, and the protocol wants the ack promptly.
        ext_session_lock_surface_v1_ack_configure(proxy, serial)
        MainActor.assumeIsolated {
            hasConfigure = true
            configuredWidth = width
            configuredHeight = height
            onConfigure?(width, height)
        }
    }
}
