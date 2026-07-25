// zwlr_foreign_toplevel_management_v1 on the router — the taskbar / window-list
// protocol, served as a thin projection of the authoritative Swift window model.
//
// The manager is the only global. Each bind creates a per-client projection that
// registers as a `DesktopModelObserver` on `NucleusCompositorServer`; registration replays
// the current windows as synthetic windowAdded/focusChanged changes through the same
// `desktopModelDidChange` path the live stream uses, so bind-time enumeration and
// streaming are one code path. For each qualifying window the projection mints a
// server-created `zwlr_foreign_toplevel_handle_v1` and emits identity + state; window
// changes restream as title/app_id/state/done, removal as `closed`.
//
// The handle holds no window state: its control requests (activate/close/maximize/
// minimize/fullscreen) funnel through the `ForeignToplevelActions` delegate (the
// router window driver), the same window-id-keyed path the compositor's own chrome
// uses. Ported from the legacy NucleusWaylandRouter/ForeignToplevel.swift.
//
// Isolation: the router dispatches on the compositor main actor. The handwritten bind
// callback enters that actor through the shared boundary, and generated request
// trampolines do the same before invoking these @MainActor protocol owners.

import WaylandServerC
internal import NucleusCompositorServer
import WaylandServer
import WaylandServerDispatch

/// The window-action seam the taskbar drives, by model window id. Implemented by the
/// router window driver, which owns the focus/configure/close mechanics.
@MainActor
protocol ForeignToplevelActions: AnyObject {
    func foreignActivate(windowID: UInt64)
    func foreignClose(windowID: UInt64)
    func foreignSetMaximized(windowID: UInt64, _ on: Bool)
    func foreignSetMinimized(windowID: UInt64, _ on: Bool)
    func foreignSetFullscreen(
        windowID: UInt64, _ on: Bool, outputID: UInt64?)
}

@MainActor
@safe final class ZwlrForeignToplevelManager {
    weak var actions: (any ForeignToplevelActions)?
    /// Resolves a client's bound wl_output for a display id (output_enter/leave).
    private unowned let compositor: WlCompositor
    fileprivate unowned let server: NucleusCompositorServer

    init(compositor: WlCompositor, server: NucleusCompositorServer) {
        self.compositor = compositor
        self.server = server
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            ZwlrForeignToplevelManagerV1Server.global(
                implementation: self,
                advertisedVersion: 3,
                owner: { manager, handle in
                    ForeignToplevelClient(
                        resource: handle,
                        manager: manager)
                },
                installed: { _, projection, _ in
                    projection.start()
                }))
    }

    /// A client's bound wl_output resource for `displayID`, or nil if unbound.
    fileprivate func outputResource(
        forClient client: WaylandClientID?, displayID: UInt64
    ) -> WaylandResourceHandle<WlOutputServer>? {
        compositor.output(id: displayID)?
            .resources(forClient: client).first
    }

    fileprivate func runActions(_ body: (any ForeignToplevelActions) -> Void) {
        if let actions { body(actions) }
    }

}

extension ForeignToplevelClient: ZwlrForeignToplevelManagerV1Requests {
    // stop: the client is done enumerating; stop observing and emit `finished`.
    func stop(_ request: WaylandRequest<ZwlrForeignToplevelManagerV1Server>) {
        stop()
    }
}

/// A single client's taskbar projection (Rule 9: owned by its manager wl_resource).
@MainActor
@safe final class ForeignToplevelClient: DesktopModelObserver {
    private unowned let manager: ZwlrForeignToplevelManager
    private let version: Int32
    private let resource:
        WaylandResourceHandle<ZwlrForeignToplevelManagerV1Server>
    /// Per-window wire handle, held weakly (the wl_resource owns it). A destroyed
    /// handle's box self-clears; the projection skips nil boxes.
    private var handles:
        [UInt64: WeakReference<ForeignToplevelHandle>] = [:]
    private var finished = false

    init(
        resource:
            WaylandResourceHandle<ZwlrForeignToplevelManagerV1Server>,
        manager: ZwlrForeignToplevelManager
    ) {
        self.resource = resource
        self.manager = manager
        version = resource.version ?? 1
    }

    /// Register as a model observer; the snapshot replay enumerates current windows.
    fileprivate func start() { manager.server.addObserver(self) }

    fileprivate func stop() {
        finished = true
        manager.server.removeObserver(self)
        resource.sendFinished()
    }

    private func handle(_ windowID: UInt64) -> ForeignToplevelHandle? {
        guard let box = handles[windowID] else { return nil }
        guard let h = box.value else {
            handles[windowID] = nil
            return nil
        }
        return h
    }

    // MARK: DesktopModelObserver

    func desktopModelDidChange(_ changes: [DesktopChange]) {
        guard !finished else { return }
        for change in changes {
            switch change {
            case let .windowAdded(id): reconcile(id)
            case let .windowChanged(id): reconcile(id)
            case let .windowRemoved(id): closeHandle(id)
            case let .focusChanged(id): refocus(to: id)
            default: break  // space changes belong to ext-workspace
            }
        }
    }

    /// A window the taskbar should list: a mapped, managed application toplevel. The
    /// shell's own layer-shell surfaces are excluded so it never enumerates itself.
    private func qualifies(_ window: Window) -> Bool {
        window.mapped && window.isManagedAppWindow() && window.layerHost == nil
    }

    private func reconcile(_ windowID: UInt64) {
        guard let managerResource = unsafe resource.resource,
              let window = manager.server.window(id: windowID)
        else { return }
        guard qualifies(window) else { closeHandle(windowID); return }
        if handle(windowID) == nil {
            unsafe createHandle(windowID, managerRes: managerResource)
        }
        guard let handle = handle(windowID) else { return }
        if handle.titleSent != window.title {
            handle.titleSent = window.title
            handle.resource.sendTitle(title: window.title)
        }
        if handle.appIdSent != window.appId {
            handle.appIdSent = window.appId
            handle.resource.sendAppId(app_id: window.appId)
        }
        syncOutput(handle, window: window)
        syncParent(handle, window: window)
        sendState(handle.resource, window: window, activated: handle.activated)
        handle.resource.sendDone()
    }

    /// Emit the v3 `parent` event when a window's parent changes (or on first
    /// projection to a v3 client). The parent handle is resolved within this client's
    /// own handle map — the toplevel-manager protocol reports parentage as a peer
    /// handle, so an unmapped/unenumerated parent projects as null (and re-emits once
    /// the parent later reconciles and this window's parent is re-evaluated).
    private func syncParent(_ handle: ForeignToplevelHandle, window: Window) {
        guard handle.resource.supportsParent else { return }
        let target: UInt64 = window.parentWindowID ?? 0
        if handle.parentSent == target { return }
        let parent = target != 0 ? self.handle(target)?.resource : nil
        if target != 0 && parent == nil {
            // The parent window exists but its handle is not yet projected to this
            // client. Send null for now, but do NOT latch parentSent — otherwise the
            // guard above would suppress the correction forever once the parent
            // reconciles. Leaving it stale lets the next reconcile of this child retry.
            handle.resource.sendParent(parent: nil)
            return
        }
        handle.resource.sendParent(parent: parent)
        handle.parentSent = target
    }

    /// Emit output_leave/output_enter when a window's output changes (or on first
    /// projection). An unresolved (unbound) output leaves the membership unset so the
    /// next change retries the enter.
    private func syncOutput(_ handle: ForeignToplevelHandle, window: Window) {
        let target = window.currentOutputID
        guard handle.outputDisplayID != target else { return }
        let client = handle.resource.clientID
        if let old = handle.outputDisplayID,
            let oldOutput = manager.outputResource(
                forClient: client, displayID: old)
        {
            handle.resource.sendOutputLeave(output: oldOutput)
            handle.outputDisplayID = nil
        }
        if let new = target,
           let newOutput = manager.outputResource(
            forClient: client, displayID: new) {
            handle.resource.sendOutputEnter(output: newOutput)
            handle.outputDisplayID = new
        }
    }

    @unsafe private func createHandle(
        _ windowID: UInt64,
        managerRes: UnsafeMutablePointer<wl_resource>
    ) {
        guard let client = unsafe wl_resource_get_client(managerRes) else { return }
        _ = unsafe ZwlrForeignToplevelHandleV1Server.createResource(
            client: client,
            version: version,
            owner: { handle in
                ForeignToplevelHandle(
                    resource: handle,
                    manager: manager,
                    windowID: windowID)
            },
            installed: { handleObj in
                self.handles[windowID] = WeakReference(handleObj)
                self.resource.sendToplevel(toplevel: handleObj.resource)
            })
    }

    private func closeHandle(_ windowID: UInt64) {
        guard let handle = handle(windowID) else { return }
        handle.resource.sendClosed()
        handles[windowID] = nil
        // The wire object lives until the client `destroy`s it (wlr lifecycle: server
        // `closed`, then client `destroy`); its handler stays attached and its windowID
        // is now stale, so late requests resolve to nil and no-op.
    }

    private func refocus(to focused: UInt64?) {
        for windowID in Array(handles.keys) {
            guard let handle = handle(windowID) else { continue }
            let shouldActivate = (windowID == focused)
            guard handle.activated != shouldActivate else { continue }
            handle.activated = shouldActivate
            guard let window = manager.server.window(id: windowID) else { continue }
            sendState(
                handle.resource, window: window,
                activated: shouldActivate)
            handle.resource.sendDone()
        }
    }

    /// The wlr state set as a wl_array of u32, carrying the window's full current
    /// state so a taskbar can render every indicator. `minimized` is reported from
    /// `Window.minimized` (a mapped-but-hidden window a taskbar can restore), not
    /// treated as a one-way unmap.
    private func sendState(
        _ resource:
            WaylandResourceHandle<ZwlrForeignToplevelHandleV1Server>,
        window: Window,
        activated: Bool
    ) {
        var states: [UInt32] = []
        if window.activeMaximized { states.append(0) }   // maximized
        if window.minimized { states.append(1) }         // minimized
        if activated { states.append(2) }                // activated
        if window.activeFullscreen { states.append(3) }  // fullscreen
        resource.sendState(state: states)
    }

    // No deinit observer removal: NucleusCompositorServer holds observers weakly and compacts
    // nil entries on the next drain, so a destroyed projection self-unregisters.
}

/// zwlr_foreign_toplevel_handle_v1 owner (Rule 9): a wire handle for one projected
/// window. Stateless beyond its window id + projected activation/output; control
/// verbs funnel through the actions delegate.
@MainActor
@safe final class ForeignToplevelHandle {
    private unowned let manager: ZwlrForeignToplevelManager
    let windowID: UInt64
    let resource:
        WaylandResourceHandle<ZwlrForeignToplevelHandleV1Server>
    /// Whether the client has been told this window is activated (mirrors focus).
    var activated: Bool = false
    /// The output the client has been told this window entered (and not yet left).
    var outputDisplayID: UInt64?
    /// The parent window the client was last told about (v3 `parent` event); `nil`
    /// means "no parent event emitted yet", `0` means the client was told the parent
    /// is null, else the parent windowID. Window IDs are monotonic and never 0, so 0
    /// is an unambiguous null sentinel. Tracked so `parent` is only re-emitted on change.
    var parentSent: UInt64?
    /// The title / app_id last sent to the client (nil = not yet sent). `.windowChanged`
    /// is coarse (output/state/minimize toggles fire it too), so these gate re-emitting
    /// the strings to actual changes.
    var titleSent: String?
    var appIdSent: String?

    init(
        resource:
            WaylandResourceHandle<ZwlrForeignToplevelHandleV1Server>,
        manager: ZwlrForeignToplevelManager,
        windowID: UInt64
    ) {
        self.resource = resource
        self.manager = manager
        self.windowID = windowID
    }

    private func act(_ body: (any ForeignToplevelActions, UInt64) -> Void) {
        manager.runActions { body($0, windowID) }
    }

    @unsafe private func act(
        requiring seat: UnsafeMutablePointer<wl_resource>?,
        requestResource: UnsafeMutablePointer<wl_resource>,
        _ body: (
            any ForeignToplevelActions, UInt64
        ) -> Void
    ) {
        guard
            let seatResource = unsafe seat,
            unsafe WaylandResource.owner(
                of: seatResource, as: SeatBinding.self) != nil,
            unsafe wl_resource_get_client(seatResource)
                == wl_resource_get_client(requestResource)
        else { return }
        manager.runActions { body($0, windowID) }
    }
}

extension ForeignToplevelHandle: ZwlrForeignToplevelHandleV1Requests {
    func setMaximized(_ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>) {
        act { $0.foreignSetMaximized(windowID: $1, true) }
    }
    func unsetMaximized(_ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>) {
        act { $0.foreignSetMaximized(windowID: $1, false) }
    }
    func setMinimized(_ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>) {
        act { $0.foreignSetMinimized(windowID: $1, true) }
    }
    func unsetMinimized(_ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>) {
        act { $0.foreignSetMinimized(windowID: $1, false) }
    }
    func activate(_ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>,
                              seat: WaylandBorrowedObject<WlSeatServer>) {
        let resource = unsafe request.resource
        unsafe act(requiring: seat.resource, requestResource: resource) {
            $0.foreignActivate(windowID: $1)
        }
    }
    func close(_ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>) {
        act { $0.foreignClose(windowID: $1) }
    }
    // set_rectangle(surface, x, y, w, h): the taskbar minimize-animation source rect;
    // advisory, ignored.
    func setRectangle(_ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>,
                                  surface: WaylandBorrowedObject<WlSurfaceServer>,
                                  x: Int32, y: Int32, width: Int32, height: Int32) {}
    func setFullscreen(_ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>,
                                   output: WaylandBorrowedObject<WlOutputServer>?) {
        let outputID = output?.output?.outputId
        act {
            $0.foreignSetFullscreen(
                windowID: $1, true, outputID: outputID)
        }
    }
    func unsetFullscreen(_ request: WaylandRequest<ZwlrForeignToplevelHandleV1Server>) {
        act {
            $0.foreignSetFullscreen(
                windowID: $1, false, outputID: nil)
        }
    }
}
