// Owner of a wl_display, its event loop, and socket lifetime. Register `eventLoopFd` once with
// your reactor / poll loop; on readiness call `dispatch()` to run all ready client work, then
// `flushClients()` before the next wait.

import Glibc
import WaylandServerC

/// The native pointers remain valid until this owner deinitializes; every
/// operation is serialized by the caller on the Wayland event-loop thread.
@MainActor
@safe package final class WaylandDisplay {
    package let display: OpaquePointer
    package let eventLoop: OpaquePointer
    private var managedClients: [WaylandManagedClient] = []
    private var globalFilter: WaylandGlobalFilter?

    package init?() {
        guard let display = unsafe wl_display_create() else { return nil }
        guard let loop = unsafe wl_display_get_event_loop(display) else {
            unsafe wl_display_destroy(display)
            return nil
        }
        // SHM is a libwayland-owned mechanism: wl_display_init_shm registers the wl_shm global and
        // implements wl_shm/wl_shm_pool/wl_buffer — pool mmap, buffer storage, refcounting —
        // entirely inside libwayland. It advertises ARGB8888 + XRGB8888 by default. A server reads
        // committed pixels at commit time through wl_shm_buffer_get(...) rather than reimplementing
        // any of this in Swift.
        guard unsafe wl_display_init_shm(display) == 0 else {
            unsafe wl_display_destroy(display)
            return nil
        }
        unsafe self.display = display
        unsafe self.eventLoop = loop
    }

    /// The aggregate epoll FD libwayland multiplexes every client and event
    /// source onto — the single descriptor a reactor watches for the whole
    /// Wayland subsystem.
    package var eventLoopFd: Int32 {
        unsafe wl_event_loop_get_fd(eventLoop)
    }

    @discardableResult
    package func addSocketAuto() -> String? {
        guard let name = unsafe wl_display_add_socket_auto(display) else { return nil }
        return unsafe String(cString: name)
    }

    @discardableResult
    package func addSocket(named name: String) -> Bool {
        name.withCString { pointer in
            unsafe wl_display_add_socket(display, pointer) == 0
        }
    }

    /// Adopt an externally created client socket (e.g. Xwayland's) as a wl_client.
    package func createClient(fd: Int32) -> OpaquePointer? {
        unsafe wl_client_create(display, fd)
    }

    /// Adopt a supervisor-provisioned connection whose lifetime must be
    /// explicitly revocable while the display remains alive.
    @MainActor
    package func createManagedClient(
        fd: Int32
    ) -> WaylandManagedClient? {
        guard let client = unsafe wl_client_create(display, fd),
            let identity = unsafe WaylandClientID(client)
        else { return nil }
        guard
            let managed = unsafe WaylandManagedClient(
                display: self,
                client: client,
                identity: identity)
        else { return nil }
        managedClients.append(managed)
        return managed
    }

    @MainActor
    fileprivate func destroyManagedClient(
        _ managed: WaylandManagedClient
    ) {
        guard let client = unsafe managed.nativeClient else { return }
        unsafe wl_client_destroy(client)
    }

    fileprivate func forgetManagedClient(
        _ managed: WaylandManagedClient
    ) {
        managedClients.removeAll { $0 === managed }
    }

    /// Install one display-wide visibility decision. libwayland evaluates it
    /// both while advertising globals and again when a client binds by name.
    @MainActor
    package func setGlobalFilter(
        _ decision:
            @escaping @MainActor (
                WaylandClientID,
                String
            ) -> Bool
    ) {
        let filter = WaylandGlobalFilter(decision)
        globalFilter = filter
        unsafe wl_display_set_global_filter(
            display,
            waylandDisplayGlobalFilter,
            Unmanaged.passUnretained(filter).toOpaque())
    }

    package func dispatch() {
        _ = unsafe wl_event_loop_dispatch(eventLoop, 0)
    }

    package func flushClients() {
        unsafe wl_display_flush_clients(display)
    }

    package func nextSerial() -> UInt32 {
        unsafe wl_display_next_serial(display)
    }

    isolated deinit {
        while let client = managedClients.last {
            client.destroy()
        }
        unsafe wl_display_set_global_filter(display, nil, nil)
        globalFilter = nil
        unsafe wl_display_destroy(display)
    }
}

@MainActor
@safe
package final class WaylandManagedClient {
    package let identity: WaylandClientID
    private weak var display: WaylandDisplay?
    private var client: OpaquePointer?
    private var lifetimeListener:
        UnsafeMutablePointer<
            swift_wayland_resource_lifetime_listener
        >?

    fileprivate init?(
        display: WaylandDisplay,
        client: OpaquePointer,
        identity: WaylandClientID
    ) {
        self.display = display
        unsafe self.client = client
        self.identity = identity
        let owner = unsafe Unmanaged.passUnretained(self).toOpaque()
        guard
            let listener =
                unsafe swift_wayland_resource_lifetime_listener_create(
                    owner,
                    waylandManagedClientDestroyed)
        else {
            unsafe wl_client_destroy(client)
            unsafe self.client = nil
            self.display = nil
            return nil
        }
        unsafe lifetimeListener = listener
        unsafe swift_wayland_client_lifetime_listener_attach(
            listener, client)
    }

    package func destroy() {
        display?.destroyManagedClient(self)
    }

    package var isAlive: Bool {
        unsafe client != nil
    }

    fileprivate var nativeClient: OpaquePointer? {
        unsafe client
    }

    fileprivate func clientDestroyed(
        _ listener:
            UnsafeMutablePointer<
                swift_wayland_resource_lifetime_listener
            >
    ) {
        guard unsafe lifetimeListener == listener else { return }
        unsafe lifetimeListener = nil
        unsafe client = nil
        let owner = display
        display = nil
        unsafe swift_wayland_resource_lifetime_listener_destroy(listener)
        owner?.forgetManagedClient(self)
    }
}

private let waylandManagedClientDestroyed:
    @convention(c) (
        UnsafeMutablePointer<wl_listener>?,
        UnsafeMutableRawPointer?
    ) -> Void = { listener, _ in
        guard let listener = unsafe listener,
            let owner = unsafe swift_wayland_resource_lifetime_listener_owner(
                listener),
            let box = unsafe swift_wayland_resource_lifetime_listener_box(
                listener)
        else { return }
        let managed = unsafe Unmanaged<WaylandManagedClient>
            .fromOpaque(owner).takeUnretainedValue()
        let actorManaged = managed
        nonisolated(unsafe) let actorBox = unsafe box
        MainActor.assumeIsolated {
            unsafe actorManaged.clientDestroyed(actorBox)
        }
    }

@MainActor
private final class WaylandGlobalFilter {
    let decision: @MainActor (WaylandClientID, String) -> Bool

    init(
        _ decision:
            @escaping @MainActor (
                WaylandClientID,
                String
            ) -> Bool
    ) {
        self.decision = decision
    }
}

private let waylandDisplayGlobalFilter:
    @convention(c) (
        OpaquePointer?,
        OpaquePointer?,
        UnsafeMutableRawPointer?
    ) -> Bool = { client, global, data in
        guard let client = unsafe client,
            let global = unsafe global,
            let data = unsafe data,
            let identity = unsafe WaylandClientID(client),
            let interface = unsafe wl_global_get_interface(global),
            let name = unsafe interface.pointee.name
        else { return false }
        let filter = unsafe Unmanaged<WaylandGlobalFilter>
            .fromOpaque(data).takeUnretainedValue()
        let interfaceName = unsafe String(cString: name)
        return MainActor.assumeIsolated {
            filter.decision(identity, interfaceName)
        }
    }
