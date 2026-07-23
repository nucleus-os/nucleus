// In-process X window manager.
//
// Connects to Xwayland's -wm fd via xcb_connect_to_fd, pumps XCB events from the
// compositor io_uring loop (the xwayland_xwm reactor token), claims _NET_WM_S0 +
// _NET_WM_CM_S0 via a hidden WM window, redirects subwindows through Composite, and
// maintains the X11-window ↔ router-surface pairing (xwayland_shell_v1 serials).
//
// The retired XwmSink + nucleus_runtime_xwayland_* crossings collapse here: window
// policy (focus / close / EWMH state / metadata) is now direct @MainActor calls into
// WindowManager, and lifecycle (create / geometry / map / destroy) drives
// RouterXwaylandDriver directly.
//
// Monitor topology (RANDR / Xinerama) is diagnostic-only — never load-bearing,
// since the compositor's own DRM layer owns real output topology — so it is
// intentionally dropped.

import Glibc
import NucleusCompositorXcbC
internal import NucleusCompositorServer
import NucleusCompositorServerTypes
internal import NucleusCompositorWindowManager

private func xwmLog(_ s: String) {
    let line = "[xwm] \(s)\n"
    _ = line.withCString { ptr in write(2, ptr, strlen(ptr)) }
}

@MainActor
final class XwaylandXWM {
    private unowned let host: RouterHost
    let conn: OpaquePointer
    /// XCB connection fd, polled by the compositor loop (xwayland_xwm token).
    let pollFd: Int32
    let rootWindow: xcb_window_t
    let rootVisual: xcb_visualid_t
    var wmWindow: xcb_window_t = 0
    var atoms: AtomTable
    let xsettings: XSettingsManager

    // XFixes cursor bridge.
    var xfixesEventBase: UInt8 = 0
    var xfixesOK = false
    var cursorW: UInt32 = 0
    var cursorH: UInt32 = 0
    var cursorHX: UInt16 = 0
    var cursorHY: UInt16 = 0
    var cursorHas = false

    // X11 window map + pairing maps (xwayland_shell_v1 serial → router surface id).
    var windowMap: [xcb_window_t: XwaylandSurface] = [:]
    var unpairedXsurfBySerial: [UInt64: XwaylandSurface] = [:]
    var unpairedRouterSurfaceBySerial: [UInt64: UInt64] = [:]

    /// Take ownership of `wmFd`, connect via XCB, claim the WM role + EWMH, enable
    /// Composite redirect, and expose the XCB fd. Returns nil on any bring-up failure.
    init?(wmFd: Int32, host: RouterHost) {
        guard let c = xcb_connect_to_fd(wmFd, nil) else { close(wmFd); return nil }
        if xcb_connection_has_error(c) != 0 { xcb_disconnect(c); return nil }
        guard let setup = xcb_get_setup(c) else { xcb_disconnect(c); return nil }
        let iter = xcb_setup_roots_iterator(setup)
        guard iter.rem != 0, let screenPtr = iter.data else { xcb_disconnect(c); return nil }
        let screen = screenPtr.pointee
        let interned = internAllAtoms(c)

        self.host = host
        self.conn = c
        self.pollFd = xcb_get_file_descriptor(c)
        self.rootWindow = screen.root
        self.rootVisual = screen.root_visual
        self.atoms = interned
        self.xsettings = XSettingsManager(
            conn: c, root: screen.root, rootVisual: screen.root_visual, atoms: interned)

        selectRootEvents()
        createWmWindow()
        claimWmSelection()
        advertiseEwmh()
        enableCompositeRedirect()
        refreshDesktopState()
        initXfixes()
        _ = xcb_flush(c)
        xwmLog("ready on root 0x\(String(rootWindow, radix: 16)), wm_window 0x\(String(wmWindow, radix: 16))")
    }

    /// Full teardown. The Xwayland wl connection is a router client (the router
    /// destroys it on disconnect); this drops the X11 side.
    func shutdown() {
        for (_, surface) in windowMap {
            destroyPairedWindow(surface)
            dissociate(surface)
        }
        windowMap.removeAll()
        unpairedXsurfBySerial.removeAll()
        unpairedRouterSurfaceBySerial.removeAll()
        xsettings.destroyWindow()
        if wmWindow != 0 {
            _ = xcb_destroy_window(conn, wmWindow)
            _ = xcb_flush(conn)
            wmWindow = 0
        }
        xcb_disconnect(conn)
    }

    // ── router driver / window model access ──────────────────────────────────
    private var driver: RouterXwaylandDriver? { host.runtime?.xwaylandDriver }

    // ── bring-up ──────────────────────────────────────────────────────────────

    private func selectRootEvents() {
        var mask: [UInt32] = [
            XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY.rawValue
                | XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT.rawValue
                | XCB_EVENT_MASK_PROPERTY_CHANGE.rawValue
        ]
        _ = xcb_change_window_attributes(conn, rootWindow, XCB_CW_EVENT_MASK.rawValue, &mask)
    }

    private func createWmWindow() {
        let wid = xcb_generate_id(conn)
        _ = xcb_create_window(
            conn, 0 /* XCB_COPY_FROM_PARENT */, wid, rootWindow,
            0, 0, 10, 10, 0,
            UInt16(XCB_WINDOW_CLASS_INPUT_OUTPUT.rawValue), rootVisual, 0, nil)
        wmWindow = wid
        changeProperty8(window: wid, property: atoms[._NET_WM_NAME], type: atoms[.UTF8_STRING], bytes: Array("Nucleus".utf8))
    }

    private func claimWmSelection() {
        _ = xcb_set_selection_owner(conn, wmWindow, atoms[.WM_S0], 0 /* XCB_CURRENT_TIME */)
        _ = xcb_set_selection_owner(conn, wmWindow, atoms[._NET_WM_CM_S0], 0)
    }

    private func enableCompositeRedirect() {
        _ = xcb_composite_redirect_subwindows(
            conn, rootWindow, UInt8(XCB_COMPOSITE_REDIRECT_MANUAL.rawValue))
    }

    private func advertiseEwmh() {
        let check: [UInt32] = [wmWindow]
        check.withUnsafeBytes { raw in
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), rootWindow,
                atoms[._NET_SUPPORTING_WM_CHECK], xcb_atom_t(XCB_ATOM_WINDOW.rawValue), 32, 1, raw.baseAddress)
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), wmWindow,
                atoms[._NET_SUPPORTING_WM_CHECK], atoms[.ATOM], 32, 1, raw.baseAddress)
        }
        changeProperty8(window: wmWindow, property: atoms[._NET_WM_NAME], type: atoms[.UTF8_STRING], bytes: Array("Nucleus".utf8))

        let supported: [xcb_atom_t] = [
            atoms[._NET_ACTIVE_WINDOW], atoms[._NET_SUPPORTING_WM_CHECK],
            atoms[._NET_NUMBER_OF_DESKTOPS], atoms[._NET_CURRENT_DESKTOP],
            atoms[._NET_DESKTOP_GEOMETRY], atoms[._NET_DESKTOP_VIEWPORT],
            atoms[._NET_WORKAREA], atoms[._NET_WM_NAME], atoms[._NET_WM_STATE],
            atoms[._NET_WM_STATE_FOCUSED], atoms[._NET_WM_STATE_FULLSCREEN],
            atoms[._NET_WM_STATE_MAXIMIZED_VERT], atoms[._NET_WM_STATE_MAXIMIZED_HORZ],
            atoms[._NET_WM_STATE_HIDDEN], atoms[._NET_WM_WINDOW_TYPE],
            atoms[._NET_CLIENT_LIST], atoms[._NET_CLIENT_LIST_STACKING],
            atoms[._NET_WM_MOVERESIZE], atoms[._NET_WM_SYNC_REQUEST],
        ]
        supported.withUnsafeBytes { raw in
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), rootWindow,
                atoms[._NET_SUPPORTED], atoms[.ATOM], 32, UInt32(supported.count), raw.baseAddress)
        }
    }

    // ── desktop state / DPI ─────────────────────────────────────────────────────

    func refreshDesktopState() {
        publishRootDesktopState()
        publishDpiSettings()
        _ = xcb_flush(conn)
    }

    func updateScale() { refreshDesktopState() }

    private func shellFractionalScale() -> Double {
        let layout = host.server.layout
        guard let id = layout.primaryDisplayID(), let display = layout.display(id: id) else {
            return layout.displays.first?.fractionalScale ?? 1.0
        }
        return display.fractionalScale
    }

    private func desktopBounds() -> (x: Double, y: Double, w: Double, h: Double) {
        guard let bounds = host.server.layout.desktopBounds() else { return (0, 0, 0, 0) }
        return (bounds.x, bounds.y, bounds.width, bounds.height)
    }

    private func logicalOffsetToCardinal(_ v: Double) -> UInt32 { UInt32(max(0.0, v.rounded())) }
    private func logicalExtentToCardinal(_ v: Double) -> UInt32 { UInt32(max(0.0, v.rounded(.up))) }

    private func publishRootDesktopState() {
        let b = desktopBounds()
        let geomW = logicalExtentToCardinal(b.w)
        let geomH = logicalExtentToCardinal(b.h)
        let workarea = desktopWorkarea()
        let cardinal = atoms[.CARDINAL]
        writeCardinals(rootWindow, atoms[._NET_NUMBER_OF_DESKTOPS], cardinal, [1])
        writeCardinals(rootWindow, atoms[._NET_CURRENT_DESKTOP], cardinal, [0])
        writeCardinals(rootWindow, atoms[._NET_DESKTOP_GEOMETRY], cardinal, [geomW, geomH])
        writeCardinals(rootWindow, atoms[._NET_DESKTOP_VIEWPORT], cardinal, [0, 0])
        writeCardinals(
            rootWindow, atoms[._NET_WORKAREA], cardinal,
            [logicalOffsetToCardinal(workarea.x),
             logicalOffsetToCardinal(workarea.y),
             logicalExtentToCardinal(workarea.w),
             logicalExtentToCardinal(workarea.h)])
    }

    private func desktopWorkarea() -> (
        x: Double, y: Double, w: Double, h: Double
    ) {
        let layout = host.server.layout
        guard !layout.displays.isEmpty else {
            return desktopBounds()
        }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for display in layout.displays {
            let frame = display.logicalRect
            let zones = host.windowManager.layerShellPolicy
                .recalcZones(outputID: display.id)
                ?? LayerExclusiveZones()
            let x = frame.x + Double(zones.left)
            let y = frame.y + Double(zones.top)
            let right = frame.maxX - Double(zones.right)
            let bottom = frame.maxY - Double(zones.bottom)
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, right)
            maxY = max(maxY, bottom)
        }
        return (
            minX, minY,
            max(0, maxX - minX),
            max(0, maxY - minY))
    }

    private func publishDpiSettings() {
        let scale = shellFractionalScale()
        setResourceManager(conn, rootWindow, atoms, scale: scale)
        xsettings.publishScale(scale)
    }

    /// Re-publish the EWMH managed-client lists in the window model's current
    /// back-to-front stacking order, plus the active Xwayland window.
    func refreshClientLists() {
        let clients = host.windowManager
            .xwaylandClientXIDs()
        clients.withUnsafeBytes { raw in
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), rootWindow,
                atoms[._NET_CLIENT_LIST],
                xcb_atom_t(XCB_ATOM_WINDOW.rawValue), 32,
                UInt32(clamping: clients.count),
                raw.baseAddress)
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), rootWindow,
                atoms[._NET_CLIENT_LIST_STACKING],
                xcb_atom_t(XCB_ATOM_WINDOW.rawValue), 32,
                UInt32(clamping: clients.count),
                raw.baseAddress)
        }
        let active: [UInt32] = [UInt32(truncatingIfNeeded: host.windowManager.activeXwaylandXID())]
        active.withUnsafeBytes { raw in
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), rootWindow,
                atoms[._NET_ACTIVE_WINDOW],
                xcb_atom_t(XCB_ATOM_WINDOW.rawValue), 32, 1,
                raw.baseAddress)
        }
        _ = xcb_flush(conn)
    }

    // ── XFixes cursor bridge ────────────────────────────────────────────────────

    private func initXfixes() {
        let verCookie = xcb_xfixes_query_version(conn, 4, 0)
        guard let verReply = xcb_xfixes_query_version_reply(conn, verCookie, nil) else {
            xwmLog("XFixes query_version failed — cursor bridge disabled"); return
        }
        free(verReply)
        var present: UInt8 = 0
        let base = nucleus_xcb_xfixes_event_base(conn, &present)
        guard present != 0 else {
            xwmLog("XFixes not present — cursor bridge disabled"); return
        }
        xfixesEventBase = base
        xfixesOK = true
        _ = xcb_xfixes_select_cursor_input(
            conn, rootWindow, UInt32(XCB_XFIXES_CURSOR_NOTIFY_MASK_DISPLAY_CURSOR.rawValue))
        fetchCursorOnly()
    }

    private func fetchCursorOnly() {
        let cookie = xcb_xfixes_get_cursor_image_and_name(conn)
        guard let reply = xcb_xfixes_get_cursor_image_and_name_reply(conn, cookie, nil) else { return }
        defer { free(reply) }
        storeCursor(reply)
    }

    private func fetchAndApplyCursor() {
        fetchCursorOnly()
        applyCurrentCursor()
    }

    private func storeCursor(_ reply: UnsafeMutablePointer<xcb_xfixes_get_cursor_image_and_name_reply_t>) {
        let w = UInt32(reply.pointee.width)
        let h = UInt32(reply.pointee.height)
        guard w != 0, h != 0 else { return }
        cursorW = w
        cursorH = h
        cursorHX = reply.pointee.xhot
        cursorHY = reply.pointee.yhot
        cursorHas = true
    }

    /// Publish the cached X cursor metadata to the Swift cursor server.
    @discardableResult
    func applyCurrentCursor() -> Bool {
        guard cursorHas else { return false }
        let cursor = host.server.cursor
        cursor.imageHandle = 0
        cursor.width = cursorW
        cursor.height = cursorH
        cursor.hotSpotX = Int32(cursorHX)
        cursor.hotSpotY = Int32(cursorHY)
        RenderBridge.requestCursorFrame(server: host.server)
        return true
    }

    // ── event pump ──────────────────────────────────────────────────────────────

    /// Drain all pending XCB events. Returns false on a fatal connection error
    /// (the loop drops the xwayland_xwm token).
    func dispatchReadable() -> Bool {
        while let raw = xcb_poll_for_event(conn) {
            dispatch(raw)
            free(raw)
        }
        if xcb_connection_has_error(conn) != 0 {
            xwmLog("XCB connection error — detaching")
            return false
        }
        _ = xcb_flush(conn)
        return true
    }

    private func bind<T>(_ raw: UnsafeMutablePointer<xcb_generic_event_t>, _ t: T.Type) -> UnsafeMutablePointer<T> {
        UnsafeMutableRawPointer(raw).assumingMemoryBound(to: T.self)
    }

    private func dispatch(_ raw: UnsafeMutablePointer<xcb_generic_event_t>) {
        let kind = Int32(raw.pointee.response_type & 0x7f)
        if xfixesOK && kind == Int32(xfixesEventBase) + XCB_XFIXES_CURSOR_NOTIFY {
            fetchAndApplyCursor()
            return
        }
        switch kind {
        case XCB_CREATE_NOTIFY: onCreateNotify(bind(raw, xcb_create_notify_event_t.self))
        case XCB_DESTROY_NOTIFY: onDestroyNotify(bind(raw, xcb_destroy_notify_event_t.self))
        case XCB_UNMAP_NOTIFY: onUnmapNotify(bind(raw, xcb_unmap_notify_event_t.self))
        case XCB_MAP_NOTIFY: onMapNotify(bind(raw, xcb_map_notify_event_t.self))
        case XCB_MAP_REQUEST: onMapRequest(bind(raw, xcb_map_request_event_t.self))
        case XCB_CONFIGURE_NOTIFY: onConfigureNotify(bind(raw, xcb_configure_notify_event_t.self))
        case XCB_CONFIGURE_REQUEST: onConfigureRequest(bind(raw, xcb_configure_request_event_t.self))
        case XCB_PROPERTY_NOTIFY: onPropertyNotify(bind(raw, xcb_property_notify_event_t.self))
        case XCB_CLIENT_MESSAGE: onClientMessage(bind(raw, xcb_client_message_event_t.self))
        default: break
        }
    }

    // ── event handlers ──────────────────────────────────────────────────────────

    private func onCreateNotify(_ ev: UnsafeMutablePointer<xcb_create_notify_event_t>) {
        let e = ev.pointee
        if e.window == wmWindow { return }
        let surface = XwaylandSurface(windowID: e.window, overrideRedirect: e.override_redirect != 0)
        surface.x = e.x
        surface.y = e.y
        surface.width = e.width
        surface.height = e.height
        windowMap[e.window] = surface
        subscribeWindow(conn, e.window)
        refreshTracked(conn, atoms, surface)
    }

    private func onDestroyNotify(_ ev: UnsafeMutablePointer<xcb_destroy_notify_event_t>) {
        let window = ev.pointee.window
        guard let surface = windowMap.removeValue(forKey: window) else { return }
        if host.windowManager.activeXwaylandXID() == UInt64(window) { clearFocus() }
        destroyPairedWindow(surface)
        dissociate(surface)
        refreshClientLists()
    }

    private func onMapRequest(_ ev: UnsafeMutablePointer<xcb_map_request_event_t>) {
        _ = xcb_map_window(conn, ev.pointee.window)
    }

    private func onMapNotify(_ ev: UnsafeMutablePointer<xcb_map_notify_event_t>) {
        guard let surface = windowMap[ev.pointee.window] else { return }
        surface.x11Mapped = true
        if !surface.overrideRedirect { setWmState(conn, atoms, surface, .normal) }
        if surface.routerWindowID != 0 { driver?.setMapped(windowID: surface.routerWindowID, mapped: true) }
        syncWindowNetState(surface)
    }

    private func onUnmapNotify(_ ev: UnsafeMutablePointer<xcb_unmap_notify_event_t>) {
        guard let surface = windowMap[ev.pointee.window] else { return }
        surface.x11Mapped = false
        if !surface.overrideRedirect { setWmState(conn, atoms, surface, .withdrawn) }
        if surface.routerWindowID != 0 { driver?.setMapped(windowID: surface.routerWindowID, mapped: false) }
        if host.windowManager.activeXwaylandXID() == UInt64(ev.pointee.window) { clearFocus() }
        syncWindowNetState(surface)
    }

    private func onConfigureNotify(_ ev: UnsafeMutablePointer<xcb_configure_notify_event_t>) {
        guard let surface = windowMap[ev.pointee.window] else { return }
        surface.x = ev.pointee.x
        surface.y = ev.pointee.y
        surface.width = ev.pointee.width
        surface.height = ev.pointee.height
        // The compositor owns the paired window's geometry (the router driver's
        // reverse configure path drives moves/resizes); X-side ConfigureNotify only
        // updates the cached rect.
    }

    private func onConfigureRequest(_ ev: UnsafeMutablePointer<xcb_configure_request_event_t>) {
        let e = ev.pointee
        let surfaceOpt = windowMap[e.window]
        let isPaired = (surfaceOpt?.routerWindowID ?? 0) != 0 && !(surfaceOpt?.overrideRedirect ?? true)

        var outX = e.x
        var outY = e.y
        var outW = e.width
        var outH = e.height
        if isPaired, let s = surfaceOpt {
            // Compositor owns position for paired non-OR windows; honor only size.
            outX = s.x
            outY = s.y
            if e.value_mask & 4 /* WIDTH */ == 0 { outW = s.width }
            if e.value_mask & 8 /* HEIGHT */ == 0 { outH = s.height }
        }
        configureWindowRaw(e.window, outX, outY, outW, outH)
        if let s = surfaceOpt {
            s.x = outX
            s.y = outY
            s.width = outW
            s.height = outH
        }
    }

    private func onPropertyNotify(_ ev: UnsafeMutablePointer<xcb_property_notify_event_t>) {
        guard let surface = windowMap[ev.pointee.window] else { return }
        refreshOne(conn, atoms, surface, ev.pointee.atom)
        if surface.routerWindowID != 0 { syncMetadata(surface.routerWindowID, surface) }
    }

    private func onClientMessage(_ ev: UnsafeMutablePointer<xcb_client_message_event_t>) {
        let e = ev.pointee
        if e.type == atoms[.WL_SURFACE_SERIAL], e.format == 32 {
            let d = e.data.data32
            let serial = (UInt64(d.1) << 32) | UInt64(d.0)
            onSurfaceSerial(e.window, serial)
            return
        }
        if e.type == atoms[.WL_SURFACE_ID], e.format == 32 {
            xwmLog("legacy WL_SURFACE_ID ClientMessage win=0x\(String(e.window, radix: 16)) (shell_v1 not bound?)")
            return
        }
        if e.type == atoms[._NET_ACTIVE_WINDOW] {
            handleNetActiveWindow(e.window)
            return
        }
        if e.type == atoms[._NET_CLOSE_WINDOW] {
            handleNetCloseWindow(e.window)
            return
        }
        if e.type == atoms[._NET_WM_STATE] {
            handleNetWmState(ev)
            return
        }
    }

    private func onSurfaceSerial(_ window: xcb_window_t, _ serial: UInt64) {
        guard let surface = windowMap[window] else { return }
        surface.serial = serial
        if let routerId = unpairedRouterSurfaceBySerial.removeValue(forKey: serial) {
            associateRouter(surface, routerId)
        } else {
            unpairedXsurfBySerial[serial] = surface
        }
    }

    private func handleNetActiveWindow(_ window: xcb_window_t) {
        guard let surface = windowMap[window], surface.routerWindowID != 0 else { return }
        driver?.activateWindow(windowID: surface.routerWindowID)
        setFocus(surface)
    }

    private func handleNetCloseWindow(_ window: xcb_window_t) {
        guard let surface = windowMap[window] else { return }
        closeWindow(surface)
    }

    private func handleNetWmState(_ ev: UnsafeMutablePointer<xcb_client_message_event_t>) {
        guard ev.pointee.format == 32 else { return }
        guard let surface = windowMap[ev.pointee.window], surface.routerWindowID != 0 else { return }
        let d = ev.pointee.data.data32
        let stateMask = netStateMask(for: [d.1, d.2], atoms)
        let plan = host.windowManager.xwaylandHandleStateRequest(
            XwaylandStateRequest(
                windowID: surface.routerWindowID, action: d.0,
                stateMask: stateMask.rawValue, sourceIndication: d.3))
        if !plan.handled {
            syncWindowNetState(surface)
            return
        }
        if plan.requestConfigure {
            driver?.applyStateConfigure(windowID: surface.routerWindowID)
        }
        if plan.raise { driver?.raiseWindow(windowID: surface.routerWindowID) }
        if plan.activate {
            driver?.activateWindow(windowID: surface.routerWindowID)
            setFocus(surface)
        }
        writeNetWmStateMask(conn, atoms, surface, plan.netState)
        _ = xcb_flush(conn)
    }

    // ── focus / close / state writeback ──────────────────────────────────────────

    func setFocus(_ surface: XwaylandSurface) {
        guard surface.routerWindowID != 0 else { return }
        applyFocusPlan(host.windowManager.xwaylandFocusPlan(windowID: surface.routerWindowID))
    }

    func clearFocus() {
        applyFocusPlan(host.windowManager.xwaylandClearFocusPlan())
    }

    private func applyFocusPlan(_ plan: XwaylandFocusPlan) {
        if plan.actions & UInt32(xwaylandFocusDenied) != 0 {
            if plan.focusedX11Window != 0, plan.deniedSyncState != 0,
                let focused = windowMap[xcb_window_t(truncatingIfNeeded: plan.focusedX11Window)] {
                writeNetWmStateMask(conn, atoms, focused, XwaylandNetState(rawValue: plan.deniedSyncState))
                _ = xcb_flush(conn)
            }
            return
        }
        let inputFocusParent: UInt8 = 2
        if plan.actions & UInt32(xwaylandFocusClear) != 0 {
            _ = xcb_set_input_focus(conn, 0, 0 /* XCB_NONE */, 0 /* XCB_CURRENT_TIME */)
        }
        if plan.actions & UInt32(xwaylandFocusSetInput) != 0, plan.focusedX11Window != 0 {
            _ = xcb_set_input_focus(
                conn, inputFocusParent, xcb_window_t(truncatingIfNeeded: plan.focusedX11Window), 0)
        }
        if plan.actions & UInt32(xwaylandFocusTakeFocus) != 0, plan.focusedX11Window != 0 {
            sendTakeFocus(xcb_window_t(truncatingIfNeeded: plan.focusedX11Window))
        }
        let active: [UInt32] = [UInt32(truncatingIfNeeded: plan.activeX11Window)]
        active.withUnsafeBytes { raw in
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), rootWindow,
                atoms[._NET_ACTIVE_WINDOW],
                xcb_atom_t(XCB_ATOM_WINDOW.rawValue), 32, 1,
                raw.baseAddress)
        }
        if plan.previousX11Window != 0, plan.previousX11Window != plan.focusedX11Window,
            let old = windowMap[xcb_window_t(truncatingIfNeeded: plan.previousX11Window)] {
            syncWindowNetState(old)
        }
        if plan.focusedX11Window != 0,
            let new = windowMap[xcb_window_t(truncatingIfNeeded: plan.focusedX11Window)] {
            syncWindowNetState(new)
        }
        refreshClientLists()
        _ = xcb_flush(conn)
    }

    func closeWindow(_ surface: XwaylandSurface) {
        guard surface.routerWindowID != 0 else { return }
        switch host.windowManager.xwaylandClosePlan(windowID: surface.routerWindowID).action {
        case UInt32(xwaylandCloseDeleteWindow): sendDeleteWindow(surface.windowID)
        case UInt32(xwaylandCloseDestroy): _ = xcb_kill_client(conn, surface.windowID)
        default: break
        }
        _ = xcb_flush(conn)
    }

    func syncWindowNetState(_ surface: XwaylandSurface) {
        guard surface.routerWindowID != 0 else { return }
        let mask = host.windowManager.xwaylandNetStateSnapshot(windowID: surface.routerWindowID)
        writeNetWmStateMask(conn, atoms, surface, mask)
    }

    // ── outbound configure (reverse crossing target) ─────────────────────────────

    private func configureWindowRaw(_ window: xcb_window_t, _ x: Int16, _ y: Int16, _ w: UInt16, _ h: UInt16) {
        let values: [UInt32] = [
            UInt32(bitPattern: Int32(x)), UInt32(bitPattern: Int32(y)), UInt32(w), UInt32(h),
        ]
        let mask: UInt16 = 1 | 2 | 4 | 8  // X | Y | WIDTH | HEIGHT
        values.withUnsafeBytes { raw in
            _ = xcb_configure_window(conn, window, mask, raw.baseAddress)
        }
    }

    /// Tell an X11 window where/how big to be (interactive move/resize of a managed
    /// window). Sends a _NET_WM_SYNC_REQUEST first if the client supports it.
    func configureWindow(_ surface: XwaylandSurface, _ x: Int16, _ y: Int16, _ w: UInt16, _ h: UInt16) {
        surface.x = x
        surface.y = y
        surface.width = w
        surface.height = h
        if surface.protocols.syncRequest, surface.syncCounter != 0 {
            surface.pendingSyncValue += 1
            sendSyncRequest(surface.windowID, surface.pendingSyncValue)
        }
        configureWindowRaw(surface.windowID, x, y, w, h)
        _ = xcb_flush(conn)
    }

    func configureWindowById(_ windowID: xcb_window_t, _ x: Int16, _ y: Int16, _ w: UInt16, _ h: UInt16) {
        guard let surface = windowMap[windowID] else { return }
        configureWindow(surface, x, y, w, h)
    }

    // ── ClientMessage senders ────────────────────────────────────────────────────

    private func sendClientMessage32(
        _ window: xcb_window_t, type: xcb_atom_t, _ d0: UInt32, _ d1: UInt32, _ d2: UInt32, _ d3: UInt32
    ) {
        var ev = xcb_client_message_event_t()
        ev.response_type = UInt8(XCB_CLIENT_MESSAGE)
        ev.format = 32
        ev.window = window
        ev.type = type
        ev.data.data32 = (d0, d1, d2, d3, 0)
        withUnsafeBytes(of: &ev) { raw in
            _ = xcb_send_event(conn, 0, window, 0, raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    private func sendSyncRequest(_ window: xcb_window_t, _ value: Int64) {
        let v = UInt64(bitPattern: value)
        sendClientMessage32(
            window, type: atoms[.WM_PROTOCOLS],
            atoms[._NET_WM_SYNC_REQUEST], 0,
            UInt32(truncatingIfNeeded: v), UInt32(truncatingIfNeeded: v >> 32))
    }

    private func sendTakeFocus(_ window: xcb_window_t) {
        sendClientMessage32(window, type: atoms[.WM_PROTOCOLS], atoms[.WM_TAKE_FOCUS], 0, 0, 0)
    }

    private func sendDeleteWindow(_ window: xcb_window_t) {
        sendClientMessage32(window, type: atoms[.WM_PROTOCOLS], atoms[.WM_DELETE_WINDOW], 0, 0, 0)
    }

    // ── pairing / model lifecycle ────────────────────────────────────────────────

    private func destroyPairedWindow(_ surface: XwaylandSurface) {
        guard surface.routerWindowID != 0 else { return }
        driver?.destroy(windowID: surface.routerWindowID)
    }

    /// Promote a paired X11 window + router surface (by object id) to a model Window.
    private func associateRouter(_ surface: XwaylandSurface, _ surfaceObjectId: UInt64) {
        let handle = driver?.createWindow(
            surfaceObjectId: UInt32(truncatingIfNeeded: surfaceObjectId),
            x11WindowID: UInt64(surface.windowID), overrideRedirect: surface.overrideRedirect,
            x: Int32(surface.x), y: Int32(surface.y),
            w: UInt32(max(1, Int(surface.width))), h: UInt32(max(1, Int(surface.height)))) ?? 0
        guard handle != 0 else {
            xwmLog("router xwayland window creation failed for win=0x\(String(surface.windowID, radix: 16))")
            return
        }
        surface.routerWindowID = handle
        driver?.applyGeometry(
            windowID: handle, x: Int32(surface.x), y: Int32(surface.y),
            w: UInt32(max(1, Int(surface.width))), h: UInt32(max(1, Int(surface.height))))
        syncMetadata(handle, surface)
        refreshClientLists()
    }

    /// Called when Xwayland's xwayland_surface_v1 role commits (router surface side).
    /// Returns true if the X11 side had already parked under this serial.
    func tryAssociateRouterSurfaceBySerial(_ serial: UInt64, _ surfaceObjectId: UInt64) -> Bool {
        if let surface = unpairedXsurfBySerial.removeValue(forKey: serial) {
            associateRouter(surface, surfaceObjectId)
            return true
        }
        unpairedRouterSurfaceBySerial[serial] = surfaceObjectId
        return false
    }

    func dissociate(_ surface: XwaylandSurface) {
        if let s = surface.serial {
            unpairedXsurfBySerial[s] = nil
            unpairedRouterSurfaceBySerial[s] = nil
        }
        surface.routerWindowID = 0
    }

    private func syncMetadata(_ windowID: UInt64, _ surface: XwaylandSurface) {
        let wm = host.windowManager
        if let title = surface.title { wm.xwaylandSetTitle(windowID: windowID, title: title) }
        if let cls = surface.className {
            wm.xwaylandSetClass(windowID: windowID, windowClass: cls, instance: surface.instance ?? "")
        }
        wm.xwaylandApplyMetadata(
            windowID: windowID,
            metadata: XwaylandWindowMetadata(
                x11WindowID: UInt64(surface.windowID),
                transientForX11: UInt64(surface.transientFor ?? 0),
                windowTypeMask: windowTypeMask(for: surface.windowTypes, atoms).rawValue,
                netStateMask: netStateMask(for: surface.states, atoms).rawValue,
                protocolMask: protocolMask(surface.protocols).rawValue,
                pid: surface.pid ?? 0,
                userTime: surface.userTime,
                overrideRedirect: surface.overrideRedirect,
                inputHint: surface.hints.input,
                urgent: surface.hints.urgent,
                decorationsOff: surface.decorationsOff))
    }

    // ── small property helpers ───────────────────────────────────────────────────

    private func changeProperty8(window: xcb_window_t, property: xcb_atom_t, type: xcb_atom_t, bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), window, property, type, 8,
                UInt32(bytes.count), raw.baseAddress)
        }
    }

    private func writeCardinals(_ window: xcb_window_t, _ property: xcb_atom_t, _ type: xcb_atom_t, _ values: [UInt32]) {
        values.withUnsafeBytes { raw in
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), window, property, type, 32,
                UInt32(values.count), raw.baseAddress)
        }
    }
}
