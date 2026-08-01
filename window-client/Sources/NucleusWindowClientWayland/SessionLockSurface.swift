// One `ext_session_lock_surface_v1` — the lock role assigned to a wl_surface, one
// per output for the duration of the lock.
//
// The configure handshake is mandatory and stricter than layer-shell's: the
// protocol requires the client to ack every configure and to attach a buffer of
// exactly the configured size. Committing a wrongly-sized buffer is a protocol
// error that kills the client — and a killed locker leaves the compositor
// holding a blank fail-closed session, so getting this wrong is not a cosmetic
// bug.

package import WaylandClientDispatch

@MainActor
@safe public final class NucleusDesktopSessionLockSurface {
    package let wlSurface: WaylandProxy<WlSurfaceClient>
    package let lockSurface: WaylandProxy<ExtSessionLockSurfaceV1Client>
    package let output: NucleusDesktopOutput

    /// The size the compositor requires this surface to be. Authoritative: a
    /// lock surface does not get to pick its own size.
    package private(set) var configuredWidth: UInt32 = 0
    package private(set) var configuredHeight: UInt32 = 0
    package private(set) var hasConfigure = false

    /// Fired on each configure with the required size. The render backend sizes
    /// its swapchain to exactly this and presents.
    package var onConfigure: ((UInt32, UInt32) -> Void)?
    private var isDestroyed = false

    package init?(
        lock: WaylandProxy<ExtSessionLockV1Client>,
        client: NucleusDesktopConnection,
        output: NucleusDesktopOutput
    ) {
        guard let surface = try? client.createSurface() else {
            return nil
        }
        guard
            let lockSurface = try? lock.getLockSurface(
                surface: surface,
                output: output.proxy)
        else {
            try? surface.destroy()
            return nil
        }
        wlSurface = surface
        self.lockSurface = lockSurface
        self.output = output
        do {
            try lockSurface.installListener(self)
        } catch {
            try? lockSurface.destroy()
            try? surface.destroy()
            return nil
        }
        // No commit here: unlike layer-shell, the compositor sends the first
        // configure unprompted, and committing a bufferless surface first is
        // not part of this protocol's handshake.
    }

    package func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        try? lockSurface.destroy()
        try? wlSurface.destroy()
    }

    isolated deinit {
        destroy()
    }
}

extension NucleusDesktopSessionLockSurface: ExtSessionLockSurfaceV1Events {
    package func configure(
        _ proxy: WaylandBorrowedProxy<ExtSessionLockSurfaceV1Client>, serial: UInt32, width: UInt32,
        height: UInt32
    ) {
        try? lockSurface.ackConfigure(serial: serial)
        hasConfigure = true
        configuredWidth = width
        configuredHeight = height
        onConfigure?(width, height)
    }
}
