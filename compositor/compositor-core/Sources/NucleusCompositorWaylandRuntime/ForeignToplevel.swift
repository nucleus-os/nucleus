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
// Isolation: the router dispatches on the compositor main actor, so the projection +
// handles are @MainActor; the C-ABI request/bind handlers are nonisolated thunks that
// assume that isolation. Handles are held weakly (their wl_resource owns them), so a
// destroyed handle self-clears from the projection with no main-actor work in deinit.

import WaylandServerC
import NucleusCompositorServer
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
final class ZwlrForeignToplevelManager {
    weak var actions: ForeignToplevelActions?
    /// Resolves a client's bound wl_output for a display id (output_enter/leave).
    private unowned let compositor: WlCompositor

    init(compositor: WlCompositor) {
        self.compositor = compositor
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zwlr_foreign_toplevel_manager_v1(), version: 3,
            impl: self, bind: Self.bind)
    }

    /// A client's bound wl_output resource for `displayID`, or nil if unbound.
    fileprivate func outputResource(
        forClient client: OpaquePointer, displayID: UInt64
    ) -> UnsafeMutablePointer<wl_resource>? {
        compositor.output(id: displayID)?.resources(forClient: client).first
    }

    fileprivate func runActions(_ body: (ForeignToplevelActions) -> Void) {
        if let actions { body(actions) }
    }

    // Nonisolated C-dispatch entry; the router dispatches on the compositor main
    // actor, so the body assumes that isolation. Only Sendable bit patterns cross the
    // boundary (the pointers are re-formed inside), matching the other router thunks.
    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client else { return }
        let clientBits = UInt(bitPattern: UnsafeRawPointer(client))
        let dataBits = UInt(bitPattern: data)
        MainActor.assumeIsolated {
            guard let clientRaw = UnsafeRawPointer(bitPattern: clientBits),
                let dataRaw = UnsafeMutableRawPointer(bitPattern: dataBits),
                let me = NucleusWaylandRouter.impl(dataRaw, as: ZwlrForeignToplevelManager.self)
            else { return }
            let clientPtr = OpaquePointer(clientRaw)
            let projection = ForeignToplevelClient(manager: me, version: version)
            guard let res = WaylandResource.create(
                client: clientPtr, interface: swift_wayland_iface_zwlr_foreign_toplevel_manager_v1(),
                version: Int32(version), id: id, vtable: ZwlrForeignToplevelManagerV1Server.vtable,
                owner: projection) else { return }
            projection.bind(res)
            projection.start()
        }
    }
}

extension ForeignToplevelClient: ZwlrForeignToplevelManagerV1Requests {
    // stop: the client is done enumerating; stop observing and emit `finished`. The
    // generated dispatch is nonisolated; re-enter the compositor main actor.
    nonisolated func stop(_ resource: UnsafeMutablePointer<wl_resource>) {
        MainActor.assumeIsolated { self.stop() }
    }
}

private final class WeakHandle {
    weak var handle: ForeignToplevelHandle?
    init(_ handle: ForeignToplevelHandle) { self.handle = handle }
}

/// A single client's taskbar projection (Rule 9: owned by its manager wl_resource).
@MainActor
final class ForeignToplevelClient: DesktopModelObserver {
    private unowned let manager: ZwlrForeignToplevelManager
    private let version: Int32
    private var resource: UnsafeMutablePointer<wl_resource>?
    /// Per-window wire handle, held weakly (the wl_resource owns it). A destroyed
    /// handle's box self-clears; the projection skips nil boxes.
    private var handles: [UInt64: WeakHandle] = [:]
    private var finished = false

    init(manager: ZwlrForeignToplevelManager, version: UInt32) {
        self.manager = manager
        self.version = Int32(version)
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Register as a model observer; the snapshot replay enumerates current windows.
    fileprivate func start() { NucleusCompositorServer.shared.addObserver(self) }

    fileprivate func stop() {
        finished = true
        NucleusCompositorServer.shared.removeObserver(self)
        if let resource { zwlr_foreign_toplevel_manager_v1_send_finished(resource) }
    }

    private func handle(_ windowID: UInt64) -> ForeignToplevelHandle? {
        guard let box = handles[windowID] else { return nil }
        guard let h = box.handle else { handles[windowID] = nil; return nil }
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
        guard let resource, let window = NucleusCompositorServer.shared.window(id: windowID) else { return }
        guard qualifies(window) else { closeHandle(windowID); return }
        if handle(windowID) == nil { createHandle(windowID, managerRes: resource) }
        guard let handle = handle(windowID) else { return }
        if handle.titleSent != window.title {
            handle.titleSent = window.title
            window.title.withCString { zwlr_foreign_toplevel_handle_v1_send_title(handle.resource, $0) }
        }
        if handle.appIdSent != window.appId {
            handle.appIdSent = window.appId
            window.appId.withCString { zwlr_foreign_toplevel_handle_v1_send_app_id(handle.resource, $0) }
        }
        syncOutput(handle, window: window)
        syncParent(handle, window: window)
        sendState(handle.resource, window: window, activated: handle.activated)
        zwlr_foreign_toplevel_handle_v1_send_done(handle.resource)
    }

    /// Emit the v3 `parent` event when a window's parent changes (or on first
    /// projection to a v3 client). The parent handle is resolved within this client's
    /// own handle map — the toplevel-manager protocol reports parentage as a peer
    /// handle, so an unmapped/unenumerated parent projects as null (and re-emits once
    /// the parent later reconciles and this window's parent is re-evaluated).
    private func syncParent(_ handle: ForeignToplevelHandle, window: Window) {
        guard version >= 3 else { return }
        let target: UInt64 = window.parentWindowID ?? 0
        if handle.parentSent == target { return }
        let parentRes: UnsafeMutablePointer<wl_resource>? =
            target != 0 ? self.handle(target)?.resource : nil
        if target != 0 && parentRes == nil {
            // The parent window exists but its handle is not yet projected to this
            // client. Send null for now, but do NOT latch parentSent — otherwise the
            // guard above would suppress the correction forever once the parent
            // reconciles. Leaving it stale lets the next reconcile of this child retry.
            zwlr_foreign_toplevel_handle_v1_send_parent(handle.resource, nil)
            return
        }
        zwlr_foreign_toplevel_handle_v1_send_parent(handle.resource, parentRes)
        handle.parentSent = target
    }

    /// Emit output_leave/output_enter when a window's output changes (or on first
    /// projection). An unresolved (unbound) output leaves the membership unset so the
    /// next change retries the enter.
    private func syncOutput(_ handle: ForeignToplevelHandle, window: Window) {
        let target = window.currentOutputID
        guard handle.outputDisplayID != target else { return }
        guard let client = wl_resource_get_client(handle.resource) else { return }
        if let old = handle.outputDisplayID,
            let oldRes = manager.outputResource(forClient: client, displayID: old)
        {
            zwlr_foreign_toplevel_handle_v1_send_output_leave(handle.resource, oldRes)
            handle.outputDisplayID = nil
        }
        if let new = target, let newRes = manager.outputResource(forClient: client, displayID: new) {
            zwlr_foreign_toplevel_handle_v1_send_output_enter(handle.resource, newRes)
            handle.outputDisplayID = new
        }
    }

    private func createHandle(_ windowID: UInt64, managerRes: UnsafeMutablePointer<wl_resource>) {
        guard let client = wl_resource_get_client(managerRes) else { return }
        let handleObj = ForeignToplevelHandle(manager: manager, windowID: windowID)
        guard let handleRes = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zwlr_foreign_toplevel_handle_v1(),
            version: version, id: 0, vtable: ZwlrForeignToplevelHandleV1Server.vtable,
            owner: handleObj) else { return }
        handleObj.bind(handleRes)
        handles[windowID] = WeakHandle(handleObj)
        zwlr_foreign_toplevel_manager_v1_send_toplevel(managerRes, handleRes)
    }

    private func closeHandle(_ windowID: UInt64) {
        guard let handle = handle(windowID) else { return }
        zwlr_foreign_toplevel_handle_v1_send_closed(handle.resource)
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
            guard let window = NucleusCompositorServer.shared.window(id: windowID) else { continue }
            sendState(handle.resource, window: window, activated: shouldActivate)
            zwlr_foreign_toplevel_handle_v1_send_done(handle.resource)
        }
    }

    /// The wlr state set as a wl_array of u32, carrying the window's full current
    /// state so a taskbar can render every indicator. `minimized` is reported from
    /// `Window.minimized` (a mapped-but-hidden window a taskbar can restore), not
    /// treated as a one-way unmap.
    private func sendState(
        _ resource: UnsafeMutablePointer<wl_resource>, window: Window, activated: Bool
    ) {
        var states: [UInt32] = []
        if window.activeMaximized { states.append(0) }   // maximized
        if window.minimized { states.append(1) }         // minimized
        if activated { states.append(2) }                // activated
        if window.activeFullscreen { states.append(3) }  // fullscreen
        var arr = wl_array()
        wl_array_init(&arr)
        for state in states {
            if let slot = wl_array_add(&arr, MemoryLayout<UInt32>.size) {
                slot.assumingMemoryBound(to: UInt32.self).pointee = state
            }
        }
        zwlr_foreign_toplevel_handle_v1_send_state(resource, &arr)
        wl_array_release(&arr)
    }

    // No deinit observer removal: NucleusCompositorServer holds observers weakly and compacts
    // nil entries on the next drain, so a destroyed projection self-unregisters.
}

/// zwlr_foreign_toplevel_handle_v1 owner (Rule 9): a wire handle for one projected
/// window. Stateless beyond its window id + projected activation/output; control
/// verbs funnel through the actions delegate.
@MainActor
final class ForeignToplevelHandle {
    private unowned let manager: ZwlrForeignToplevelManager
    let windowID: UInt64
    /// Set after bind; the projection only emits to a bound handle.
    private(set) var resource: UnsafeMutablePointer<wl_resource>! = nil
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

    init(manager: ZwlrForeignToplevelManager, windowID: UInt64) {
        self.manager = manager
        self.windowID = windowID
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Re-enter the compositor main actor and run a verb against the action delegate.
    /// The generated dispatch is nonisolated but the router only drives it on the main
    /// actor, so `assumeIsolated` reasserts that.
    private nonisolated func act(_ body: @escaping @MainActor (ForeignToplevelActions, UInt64) -> Void) {
        MainActor.assumeIsolated {
            self.manager.runActions { body($0, self.windowID) }
        }
    }

    private nonisolated func act(
        requiring seat: UnsafeMutablePointer<wl_resource>?,
        requestResource: UnsafeMutablePointer<wl_resource>,
        _ body: @escaping @MainActor (
            ForeignToplevelActions, UInt64
        ) -> Void
    ) {
        let seatAddress = seat.map(UInt.init(bitPattern:)) ?? 0
        let requestAddress = UInt(bitPattern: requestResource)
        MainActor.assumeIsolated {
            guard
                let seatResource = UnsafeMutablePointer<wl_resource>(
                    bitPattern: seatAddress),
                let request = UnsafeMutablePointer<wl_resource>(
                    bitPattern: requestAddress),
                WaylandResource.owner(
                    of: seatResource, as: SeatBinding.self) != nil,
                wl_resource_get_client(seatResource)
                    == wl_resource_get_client(request)
            else { return }
            self.manager.runActions { body($0, self.windowID) }
        }
    }
}

extension ForeignToplevelHandle: ZwlrForeignToplevelHandleV1Requests {
    nonisolated func setMaximized(_ resource: UnsafeMutablePointer<wl_resource>) {
        act { $0.foreignSetMaximized(windowID: $1, true) }
    }
    nonisolated func unsetMaximized(_ resource: UnsafeMutablePointer<wl_resource>) {
        act { $0.foreignSetMaximized(windowID: $1, false) }
    }
    nonisolated func setMinimized(_ resource: UnsafeMutablePointer<wl_resource>) {
        act { $0.foreignSetMinimized(windowID: $1, true) }
    }
    nonisolated func unsetMinimized(_ resource: UnsafeMutablePointer<wl_resource>) {
        act { $0.foreignSetMinimized(windowID: $1, false) }
    }
    nonisolated func activate(_ resource: UnsafeMutablePointer<wl_resource>,
                              seat: UnsafeMutablePointer<wl_resource>?) {
        act(requiring: seat, requestResource: resource) {
            $0.foreignActivate(windowID: $1)
        }
    }
    nonisolated func close(_ resource: UnsafeMutablePointer<wl_resource>) {
        act { $0.foreignClose(windowID: $1) }
    }
    // set_rectangle(surface, x, y, w, h): the taskbar minimize-animation source rect;
    // advisory, ignored.
    nonisolated func setRectangle(_ resource: UnsafeMutablePointer<wl_resource>,
                                  surface: UnsafeMutablePointer<wl_resource>?,
                                  x: Int32, y: Int32, width: Int32, height: Int32) {}
    nonisolated func setFullscreen(_ resource: UnsafeMutablePointer<wl_resource>,
                                   output: UnsafeMutablePointer<wl_resource>?) {
        let outputAddress = output.map(UInt.init(bitPattern:)) ?? 0
        act {
            let outputResource = UnsafeMutablePointer<wl_resource>(
                bitPattern: outputAddress)
            $0.foreignSetFullscreen(
                windowID: $1,
                true,
                outputID: WlOutput.from(outputResource)?.outputId)
        }
    }
    nonisolated func unsetFullscreen(_ resource: UnsafeMutablePointer<wl_resource>) {
        act {
            $0.foreignSetFullscreen(
                windowID: $1, false, outputID: nil)
        }
    }
}
