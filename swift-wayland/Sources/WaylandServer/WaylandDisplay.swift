// Owner of a wl_display, its event loop, and socket lifetime. Register `eventLoopFd` once with
// your reactor / poll loop; on readiness call `dispatch()` to run all ready client work, then
// `flushClients()` before the next wait.

import Glibc
import WaylandServerC

public final class WaylandDisplay {
    public let display: OpaquePointer
    public let eventLoop: OpaquePointer

    public init?() {
        guard let display = wl_display_create() else { return nil }
        guard let loop = wl_display_get_event_loop(display) else {
            wl_display_destroy(display)
            return nil
        }
        // SHM is a libwayland-owned mechanism: wl_display_init_shm registers the wl_shm global and
        // implements wl_shm/wl_shm_pool/wl_buffer — pool mmap, buffer storage, refcounting —
        // entirely inside libwayland. It advertises ARGB8888 + XRGB8888 by default. A server reads
        // committed pixels at commit time through wl_shm_buffer_get(...) rather than reimplementing
        // any of this in Swift.
        guard wl_display_init_shm(display) == 0 else {
            wl_display_destroy(display)
            return nil
        }
        self.display = display
        self.eventLoop = loop
    }

    /// The aggregate epoll FD libwayland multiplexes every client and event
    /// source onto — the single descriptor a reactor watches for the whole
    /// Wayland subsystem.
    public var eventLoopFd: Int32 { wl_event_loop_get_fd(eventLoop) }

    @discardableResult
    public func addSocketAuto() -> String? {
        guard let name = wl_display_add_socket_auto(display) else { return nil }
        return String(cString: name)
    }

    /// Adopt an externally created client socket (e.g. Xwayland's) as a wl_client.
    public func createClient(fd: Int32) -> OpaquePointer? {
        wl_client_create(display, fd)
    }

    public func dispatch() { _ = wl_event_loop_dispatch(eventLoop, 0) }

    public func flushClients() { wl_display_flush_clients(display) }

    deinit { wl_display_destroy(display) }
}
