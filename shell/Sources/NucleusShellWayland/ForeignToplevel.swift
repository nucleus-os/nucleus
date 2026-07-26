// The wlr-foreign-toplevel-management client — the taskbar / window-switcher model. Binds
// zwlr_foreign_toplevel_manager_v1 and tracks every toplevel the compositor exposes: title,
// app_id, state, and the actions to drive it (activate/close/maximize/minimize/fullscreen).
//
// This is the client consumer of the same window model the compositor projects. The shell
// holds only wire-handle bookkeeping; the window state and the action behavior are the
// compositor's. The runtime projects `windows` into typed native product state and routes typed
// taskbar actions directly back through the handle.

public import WaylandClientDispatch

/// A window as seen over foreign-toplevel. Value snapshot the native taskbar reads.
public struct ToplevelWindow: Identifiable, Sendable {
    public let id: UInt64
    public var title: String = ""
    public var appID: String = ""
    public var activated: Bool = false
    public var maximized: Bool = false
    public var minimized: Bool = false
    public var fullscreen: Bool = false
}

@MainActor
@safe public final class ForeignToplevelManager {
    private let manager:
        WaylandProxy<ZwlrForeignToplevelManagerV1Client>
    private weak var client: ShellWaylandClient?

    /// Live windows keyed by handle id, in arrival order.
    public private(set) var windows: [ToplevelWindow] = []
    /// Fired (coalesced per `done`) whenever the window set or any window's state changes.
    public var onChanged: (() -> Void)?

    // Per-handle: the proxy, a scratch record accumulating events until `done` publishes it,
    // and a back-reference to the owning manager so the handle's events can publish/remove.
    @MainActor
    @safe fileprivate final class HandleBox {
        let handle:
            WaylandProxy<ZwlrForeignToplevelHandleV1Client>
        let id: UInt64
        var pending = ToplevelWindow(id: 0)
        // Weak to avoid a retain cycle (the manager retains the box via `handles`).
        weak var manager: ForeignToplevelManager?
        init(
            handle:
                WaylandProxy<
                    ZwlrForeignToplevelHandleV1Client
                >,
            id: UInt64
        ) {
            self.handle = handle
            self.id = id
            self.pending = ToplevelWindow(id: id)
        }
    }
    private var handles: [UInt64: HandleBox] = [:]

    public init?(client: ShellWaylandClient) {
        guard let manager = client.foreignToplevel else { return nil }
        self.manager = manager
        self.client = client
        do {
            try manager.installListener(self)
        } catch {
            return nil
        }
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
            try? box.handle.destroy()
        }
        handles[id] = nil
        windows.removeAll { $0.id == id }
        onChanged?()
    }

    // MARK: - Actions (routed from the native taskbar → the compositor's model)

    public func activate(id: UInt64) {
        guard let box = handles[id],
              let seat = client?.seat
        else {
            return
        }
        try? box.handle.activate(seat: seat)
    }
    public func close(id: UInt64) {
        guard let box = handles[id] else { return }
        try? box.handle.close()
    }
    public func setMinimized(id: UInt64, _ minimized: Bool) {
        guard let box = handles[id] else { return }
        if minimized {
            try? box.handle.setMinimized()
        } else {
            try? box.handle.unsetMinimized()
        }
    }
    public func setMaximized(id: UInt64, _ maximized: Bool) {
        guard let box = handles[id] else { return }
        if maximized {
            try? box.handle.setMaximized()
        } else {
            try? box.handle.unsetMaximized()
        }
    }
    public func setFullscreen(id: UInt64, _ fullscreen: Bool) {
        guard let box = handles[id] else { return }
        if fullscreen {
            try? box.handle.setFullscreen(output: nil)
        } else {
            try? box.handle.unsetFullscreen()
        }
    }
}

extension ForeignToplevelManager: ZwlrForeignToplevelManagerV1Events {
    public func toplevel(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelManagerV1Client>,
        toplevel: WaylandProxy<ZwlrForeignToplevelHandleV1Client>
    ) {
        let box = HandleBox(
            handle: toplevel,
            id: UInt64(toplevel.identity))
        do {
            try toplevel.installListener(box)
            register(box)
        } catch {
            try? toplevel.destroy()
        }
    }
    public func finished(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelManagerV1Client>
    ) {}
}

extension ForeignToplevelManager.HandleBox: ZwlrForeignToplevelHandleV1Events {
    func title(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        title: String
    ) {
        pending.title = title
    }
    func appId(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        app_id: String
    ) {
        pending.appID = app_id
    }
    func outputEnter(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        output: WaylandBorrowedProxy<WlOutputClient>
    ) {}
    func outputLeave(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        output: WaylandBorrowedProxy<WlOutputClient>
    ) {}
    func state(
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
    func parent(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>,
        parent: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>?
    ) {}
    func done(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>
    ) {
        manager?.publish(pending)
    }
    func closed(
        _ proxy: WaylandBorrowedProxy<ZwlrForeignToplevelHandleV1Client>
    ) {
        manager?.removeHandle(id: id)
    }
}
