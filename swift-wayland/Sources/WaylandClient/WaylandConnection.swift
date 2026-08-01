// Owner of a wl_display client connection and its event-loop integration — the client mirror of the
// server's WaylandDisplay. Runtime reads are prepared here and completed by the process's one reactor;
// the only blocking operation is the explicitly setup-only bootstrap roundtrip.

import WaylandClientC
import WaylandClientDispatch

#if canImport(Glibc)
import Glibc
#endif

/// Owns the native display pointer until `deinit`. The process's single reactor
/// serializes all access to the connection and any prepared read.
@MainActor
@safe package final class WaylandConnection {
    package let display: OpaquePointer
    package let connectionLifetime: WaylandClientConnectionLifetime
    private let displayProxy: WaylandProxy<WlDisplayClient>
    private weak var activeRead: WaylandPreparedRead?

    /// Connect to a compositor. `socket` names an explicit Wayland socket; nil uses $WAYLAND_DISPLAY
    /// (then the default). Returns nil if no compositor is reachable.
    package init?(socket: String? = nil) {
        let connected: OpaquePointer?
        if let socket {
            unsafe connected = wl_display_connect(socket)
        } else {
            unsafe connected = wl_display_connect(nil)
        }
        guard let d = unsafe connected else {
            return nil
        }
        unsafe display = d
        let lifetime = unsafe WaylandClientConnectionLifetime(
            adopting: d)
        connectionLifetime = lifetime
        unsafe displayProxy = WaylandProxy(
            adopting: d,
            connectionLifetime: lifetime,
            destroysNativeProxyLocally: false)
    }

    /// Adopt an already-connected fd — one end of a socketpair (for an in-process server, as a nested
    /// compositor or a conformance loopback) or an inherited connection. The fd's ownership transfers
    /// to libwayland (closed on disconnect).
    package init?(fd: Int32) {
        guard let d = unsafe wl_display_connect_to_fd(fd) else { return nil }
        unsafe display = d
        let lifetime = unsafe WaylandClientConnectionLifetime(
            adopting: d)
        connectionLifetime = lifetime
        unsafe displayProxy = WaylandProxy(
            adopting: d,
            connectionLifetime: lifetime,
            destroysNativeProxyLocally: false)
    }

    /// The display fd, for poll()-based loop integration.
    package var fd: Int32 { unsafe wl_display_get_fd(display) }

    /// The registry proxy (each call returns a fresh owned `wl_registry`).
    package func getRegistry()
        throws(WaylandProxyError) -> WaylandProxy<WlRegistryClient>
    {
        try displayProxy.getRegistry()
    }

    /// Dispatch only events already buffered, without blocking on the socket.
    @discardableResult
    package func dispatchPending() -> Int32 { unsafe wl_display_dispatch_pending(display) }

    /// Apply pending requests and flush them to the compositor.
    ///
    /// Returns the libwayland result so an event loop can distinguish write
    /// backpressure (`-1`/`EAGAIN`) from a disconnected compositor.
    @discardableResult
    package func flush() -> Int32 { unsafe wl_display_flush(display) }

    /// Block until the server has processed everything issued so far during bootstrap.
    /// Runtime event loops must use `prepareRead()` instead.
    @discardableResult
    package func bootstrapRoundtrip() -> Int32 {
        precondition(activeRead == nil, "cannot roundtrip during a prepared read")
        return unsafe wl_display_roundtrip(display)
    }

    /// Dispatch buffered events until libwayland grants one socket-read transaction.
    /// The caller must then flush requests, wait for `fd` in its reactor, and complete
    /// or cancel the returned read exactly once.
    package func prepareRead() -> WaylandReadPreparation? {
        precondition(activeRead == nil, "only one Wayland read may be prepared")
        var dispatched: Int32 = 0
        while unsafe wl_display_prepare_read(display) != 0 {
            let result = unsafe wl_display_dispatch_pending(display)
            if result < 0 { return nil }
            dispatched &+= result
        }
        let read = WaylandPreparedRead(connection: self)
        activeRead = read
        return WaylandReadPreparation(
            dispatchedEventCount: dispatched,
            read: read)
    }

    fileprivate func finishRead(_ read: WaylandPreparedRead, readable: Bool)
        -> Int32
    {
        precondition(activeRead === read, "finishing an inactive Wayland read")
        activeRead = nil
        if readable {
            guard unsafe wl_display_read_events(display) >= 0 else { return -1 }
        } else {
            unsafe wl_display_cancel_read(display)
        }
        return unsafe wl_display_dispatch_pending(display)
    }

    fileprivate func cancelRead(_ read: WaylandPreparedRead) {
        guard activeRead === read else { return }
        activeRead = nil
        unsafe wl_display_cancel_read(display)
    }

    isolated deinit {
        precondition(activeRead == nil, "disconnecting during a prepared Wayland read")
    }
}

@MainActor
package struct WaylandReadPreparation {
    /// Events that were already buffered and dispatched before the socket read was prepared.
    package let dispatchedEventCount: Int32
    package let read: WaylandPreparedRead
}

/// One granted libwayland read transaction. It must be completed after the owning
/// reactor wait or explicitly cancelled when that wait does not happen.
@MainActor
package final class WaylandPreparedRead {
    private let connection: WaylandConnection
    private var isActive = true

    fileprivate init(connection: WaylandConnection) {
        self.connection = connection
    }

    /// Read the display socket when the reactor reported it readable, or cancel
    /// the prepared read for every other wakeup. Then dispatch buffered events.
    @discardableResult
    package func complete(readable: Bool) -> Int32 {
        precondition(isActive, "Wayland read completed more than once")
        isActive = false
        return connection.finishRead(self, readable: readable)
    }

    /// Cancel a prepared read when its reactor wait cannot run or throws.
    package func cancel() {
        guard isActive else { return }
        isActive = false
        connection.cancelRead(self)
    }

    isolated deinit { cancel() }
}
