// The wlr-foreign-toplevel-management client — the taskbar / window-switcher model. Binds
// zwlr_foreign_toplevel_manager_v1 and tracks every toplevel the compositor exposes: title,
// app_id, state, and the actions to drive it (activate/close/maximize/minimize/fullscreen).
//
// This is the client consumer of the same window model the compositor projects. The shell
// holds only wire-handle bookkeeping; the window state and the action behavior are the
// compositor's. The runtime projects `windows` into typed native product state and routes typed
// taskbar actions directly back through the handle.

import WaylandClientC
public import WaylandClientDispatch

/// A window as seen over foreign-toplevel. Value snapshot the native taskbar reads.
public struct ToplevelWindow: Identifiable, Sendable {
    public let id: UInt64          // stable per-handle id (the proxy pointer bits)
    public var title: String = ""
    public var appID: String = ""
    public var activated: Bool = false
    public var maximized: Bool = false
    public var minimized: Bool = false
    public var fullscreen: Bool = false
}

@MainActor
@safe public final class ForeignToplevelManager {
    private let manager: OpaquePointer
    private weak var client: ShellWaylandClient?

    /// Live windows keyed by handle id, in arrival order.
    public private(set) var windows: [ToplevelWindow] = []
    /// Fired (coalesced per `done`) whenever the window set or any window's state changes.
    public var onChanged: (() -> Void)?

    // Per-handle: the proxy, a scratch record accumulating events until `done` publishes it,
    // and a back-reference to the owning manager so the handle's events can publish/remove.
    @safe fileprivate final class HandleBox {
        let handle: OpaquePointer
        let id: UInt64
        var pending = ToplevelWindow(id: 0)
        // Weak to avoid a retain cycle (the manager retains the box via `handles`).
        weak var manager: ForeignToplevelManager?
        init(handle: OpaquePointer, id: UInt64) {
            unsafe self.handle = handle
            self.id = id
            self.pending = ToplevelWindow(id: id)
        }
    }
    private var handles: [UInt64: HandleBox] = [:]

    public init?(client: ShellWaylandClient) {
        guard let manager = unsafe client.proxy(.foreignToplevel) else { return nil }
        unsafe self.manager = manager
        self.client = client
        installManagerListener()
    }

    private func installManagerListener() {
        unsafe ZwlrForeignToplevelManagerV1Client.addListener(manager, owner: self)
    }

    // Register a freshly-created per-handle box into the live window set (main-actor state).
    fileprivate func register(_ box: HandleBox) {
        box.manager = self
        handles[box.id] = box
        windows.append(box.pending)
    }

    fileprivate func publish(_ window: ToplevelWindow) {
        if let i = windows.firstIndex(where: { $0.id == window.id }) {
            windows[i] = window
        }
        onChanged?()
    }

    fileprivate func removeHandle(id: UInt64) {
        if let box = handles[id] {
            unsafe zwlr_foreign_toplevel_handle_v1_destroy(box.handle)
        }
        handles[id] = nil
        windows.removeAll { $0.id == id }
        onChanged?()
    }

    // MARK: - Actions (routed from the native taskbar → the compositor's model)

    public func activate(id: UInt64) {
        guard let box = handles[id], let seat = unsafe client?.proxy(.seat) else { return }
        unsafe zwlr_foreign_toplevel_handle_v1_activate(box.handle, seat)
    }
    public func close(id: UInt64) {
        guard let box = handles[id] else { return }
        unsafe zwlr_foreign_toplevel_handle_v1_close(box.handle)
    }
    public func setMinimized(id: UInt64, _ minimized: Bool) {
        guard let box = handles[id] else { return }
        if minimized { unsafe zwlr_foreign_toplevel_handle_v1_set_minimized(box.handle) }
        else { unsafe zwlr_foreign_toplevel_handle_v1_unset_minimized(box.handle) }
    }
    public func setMaximized(id: UInt64, _ maximized: Bool) {
        guard let box = handles[id] else { return }
        if maximized { unsafe zwlr_foreign_toplevel_handle_v1_set_maximized(box.handle) }
        else { unsafe zwlr_foreign_toplevel_handle_v1_unset_maximized(box.handle) }
    }
    public func setFullscreen(id: UInt64, _ fullscreen: Bool) {
        guard let box = handles[id] else { return }
        if fullscreen { unsafe zwlr_foreign_toplevel_handle_v1_set_fullscreen(box.handle, nil) }
        else { unsafe zwlr_foreign_toplevel_handle_v1_unset_fullscreen(box.handle) }
    }
}

// The manager's `toplevel` event delivers a brand-new handle proxy. We build its per-handle owner
// box, wire the handle listener (a C call, so the new proxy stays out of the actor hop), then send
// the box into the main actor to register it. The generated dispatch is nonisolated.
extension ForeignToplevelManager: ZwlrForeignToplevelManagerV1Events {
    public nonisolated func toplevel(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelManagerV1Client>,
        toplevel: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>
    ) {
        let bits = unsafe Int(bitPattern: UnsafeRawPointer(toplevel.proxy))
        MainActor.assumeIsolated {
            guard let h = unsafe OpaquePointer(bitPattern: bits) else { return }
            let box = unsafe HandleBox(handle: h, id: UInt64(UInt(bitPattern: bits)))
            unsafe ZwlrForeignToplevelHandleV1Client.addListener(h, owner: box)
            register(box)
        }
    }
    public nonisolated func finished(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelManagerV1Client>
    ) {}
}

// The per-handle owner. Not @MainActor, so its own scratch `pending` is mutated directly; only the
// cross-object publish/remove (which touch the @MainActor manager's state) hop onto the main actor,
// carrying just Sendable values (the Sendable manager reference, the window snapshot, the id).
extension ForeignToplevelManager.HandleBox: ZwlrForeignToplevelHandleV1Events {
    nonisolated func title(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        title: String
    ) {
        pending.title = title
    }
    nonisolated func appId(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        app_id: String
    ) {
        pending.appID = app_id
    }
    nonisolated func outputEnter(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        output: WaylandBorrowedProxy<WlOutputClient>
    ) {}
    nonisolated func outputLeave(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        output: WaylandBorrowedProxy<WlOutputClient>
    ) {}
    nonisolated func state(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        state: WaylandClientArrayView
    ) {
        pending.maximized = false
        pending.minimized = false
        pending.activated = false
        pending.fullscreen = false
        guard let states = state.copiedElements(of: UInt32.self) else {
            return
        }
        for value in states {
            switch value {
            case 0: pending.maximized = true
            case 1: pending.minimized = true
            case 2: pending.activated = true
            case 3: pending.fullscreen = true
            default: break
            }
        }
    }
    nonisolated func parent(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        parent: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>?
    ) {}
    nonisolated func done(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>
    ) {
        let mgr = manager                 // Sendable (@MainActor class)
        let snapshot = pending            // ToplevelWindow is Sendable
        MainActor.assumeIsolated { mgr?.publish(snapshot) }
    }
    nonisolated func closed(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>
    ) {
        let mgr = manager
        let handleID = id
        MainActor.assumeIsolated { mgr?.removeHandle(id: handleID) }
    }
}
