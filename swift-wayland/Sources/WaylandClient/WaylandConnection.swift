// Owner of a wl_display client connection and its event-loop integration — the client mirror of the
// server's WaylandDisplay. Connect, hand `fd` to your poll/reactor loop, `dispatch()` when it reports
// readable, and `flush()` at the end of each frame. `roundtrip()` blocks until the server has answered
// everything issued so far (used at setup, e.g. before reading the registry's initial globals).

import WaylandClientC
#if canImport(Glibc)
import Glibc
#endif

public final class WaylandConnection {
    public let display: OpaquePointer

    /// Connect to a compositor. `socket` names an explicit Wayland socket; nil uses $WAYLAND_DISPLAY
    /// (then the default). Returns nil if no compositor is reachable.
    public init?(socket: String? = nil) {
        guard let d = socket.map({ wl_display_connect($0) }) ?? wl_display_connect(nil) else {
            return nil
        }
        display = d
    }

    /// Adopt an already-connected fd — one end of a socketpair (for an in-process server, as a nested
    /// compositor or a conformance loopback) or an inherited connection. The fd's ownership transfers
    /// to libwayland (closed on disconnect).
    public init?(fd: Int32) {
        guard let d = wl_display_connect_to_fd(fd) else { return nil }
        display = d
    }

    /// The display fd, for poll()-based loop integration.
    public var fd: Int32 { wl_display_get_fd(display) }

    /// The registry proxy (each call returns a fresh wl_registry). A WaylandRegistry owns one.
    public func getRegistry() -> OpaquePointer? { wl_display_get_registry(display) }

    /// Drain queued events — call after poll() reports the fd readable. Returns the number of events
    /// dispatched, or -1 on error.
    @discardableResult
    public func dispatch() -> Int32 { wl_display_dispatch(display) }

    /// Dispatch only events already buffered, without blocking on the socket.
    @discardableResult
    public func dispatchPending() -> Int32 { wl_display_dispatch_pending(display) }

    /// Apply pending requests and flush them to the compositor.
    ///
    /// Returns the libwayland result so an event loop can distinguish write
    /// backpressure (`-1`/`EAGAIN`) from a disconnected compositor.
    @discardableResult
    public func flush() -> Int32 { wl_display_flush(display) }

    /// Block until the server has processed everything issued so far. Returns -1 on error.
    @discardableResult
    public func roundtrip() -> Int32 { wl_display_roundtrip(display) }

    /// One non-blocking read+dispatch cycle — never blocks on the socket. Flushes pending requests,
    /// polls the fd with a zero timeout, and reads + dispatches whatever events are already available.
    /// Use to pump an in-process loopback where a blocking roundtrip would deadlock (the peer server
    /// only advances when you pump it too). Returns the number of events dispatched, or -1 on error.
    @discardableResult
    public func pumpNonBlocking() -> Int32 {
        while wl_display_prepare_read(display) != 0 {
            if wl_display_dispatch_pending(display) < 0 { return -1 }
        }
        _ = wl_display_flush(display)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 0) }
        if ready > 0 {
            if wl_display_read_events(display) < 0 { return -1 }
        } else {
            wl_display_cancel_read(display)
        }
        return wl_display_dispatch_pending(display)
    }

    deinit { wl_display_disconnect(display) }
}
