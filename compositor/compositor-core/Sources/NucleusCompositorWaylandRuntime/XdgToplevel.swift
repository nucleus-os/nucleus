// ConfigurePolicy by the production router.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

final class XdgToplevel {
    unowned let shell: XdgShell
    weak var xdgSurface: XdgSurface?
    private(set) var resource: UnsafeMutablePointer<wl_resource>?
    /// The most recent window geometry the surface declared (visible content rect).
    var windowGeometry: WlRect? { xdgSurface?.windowGeometry }
    private var minWidth: Int32 = 0
    private var minHeight: Int32 = 0
    private var maxWidth: Int32 = 0
    private var maxHeight: Int32 = 0
    weak var protocolParent: XdgToplevel?
    weak var decoration: XdgToplevelDecoration?
    var isMapped: Bool { xdgSurface?.isMapped == true }

    init(shell: XdgShell, xdgSurface: XdgSurface) {
        self.shell = shell
        self.xdgSurface = xdgSurface
        shell.registerToplevel(self)
    }

    package func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Send xdg_toplevel.configure(width, height, states) — the states serialized
    /// into the configure's wl_array as little-endian u32s.
    func sendConfigure(_ plan: XdgToplevelConfigure) {
        guard let resource else { return }
        var states = wl_array()
        wl_array_init(&states)
        for state in plan.states {
            if let slot = wl_array_add(&states, MemoryLayout<UInt32>.size) {
                slot.assumingMemoryBound(to: UInt32.self).pointee = state
            }
        }
        xdg_toplevel_send_configure(resource, plan.width, plan.height, &states)
        wl_array_release(&states)
    }

    /// Ask the client to close (xdg_toplevel.close).
    func sendClose() {
        if let resource { xdg_toplevel_send_close(resource) }
    }

    private func request(_ r: XdgToplevelRequest, replan: Bool) {
        shell.delegate?.toplevelDidRequest(self, r)
        if replan { xdgSurface?.configureToplevel(initial: false) }
    }

    func applyProtocolParent(_ parent: XdgToplevel?) {
        protocolParent = parent
        request(.setParent(parent), replan: false)
    }

    private func wouldCreateParentCycle(_ parent: XdgToplevel) -> Bool {
        var ancestor: XdgToplevel? = parent
        while let current = ancestor {
            if current === self { return true }
            ancestor = current.protocolParent
        }
        return false
    }

    deinit {
        shell.toplevelDidUnmap(self)
        shell.unregisterToplevel(self)
        xdgSurface?.roleObjectDestroyed(self)
        shell.delegate?.toplevelWillDestroy(self)
    }
}

extension XdgToplevel: XdgToplevelRequests {
    func destroy(_ resource: UnsafeMutablePointer<wl_resource>) {
        shell.toplevelDidUnmap(self)
        xdgSurface?.roleObjectDestroyed(self)
        wl_resource_destroy(resource)
    }

    func setParent(
        _ resource: UnsafeMutablePointer<wl_resource>, parent parentRes: UnsafeMutablePointer<wl_resource>?
    ) {
        let requested = parentRes.flatMap {
            WaylandResource.owner(of: $0, as: XdgToplevel.self)
        }
        if let requested, requested === self || wouldCreateParentCycle(requested) {
            WaylandProtocolError(
                resource,
                XdgToplevelProtocolError.invalidParent,
                "parent must not be the toplevel or one of its descendants"
            ).post()
            return
        }
        applyProtocolParent(requested?.isMapped == true ? requested : nil)
    }

    func setTitle(_ resource: UnsafeMutablePointer<wl_resource>, title: UnsafePointer<CChar>?) {
        request(.setTitle(title.map { String(cString: $0) } ?? ""), replan: false)
    }

    func setAppId(_ resource: UnsafeMutablePointer<wl_resource>, app_id: UnsafePointer<CChar>?) {
        request(.setAppId(app_id.map { String(cString: $0) } ?? ""), replan: false)
    }

    func showWindowMenu(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?,
        serial: UInt32, x: Int32, y: Int32
    ) {
        guard shell.delegate?.authorizeInteractiveRequest(
            self, seat: seat, serial: serial) == true
        else { return }
        request(.showWindowMenu(serial: serial, x: x, y: y), replan: false)
    }

    func move(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?, serial: UInt32
    ) {
        guard shell.delegate?.authorizeInteractiveRequest(
            self, seat: seat, serial: serial) == true
        else { return }
        request(.move(serial: serial), replan: false)
    }

    func resize(
        _ resource: UnsafeMutablePointer<wl_resource>, seat: UnsafeMutablePointer<wl_resource>?,
        serial: UInt32, edges: UInt32
    ) {
        let validEdges: Set<UInt32> = [1, 2, 4, 5, 6, 8, 9, 10]
        guard validEdges.contains(edges) else {
            WaylandProtocolError(
                resource,
                XdgToplevelProtocolError.invalidResizeEdge,
                "invalid resize edge"
            ).post()
            return
        }
        guard shell.delegate?.authorizeInteractiveRequest(
            self, seat: seat, serial: serial) == true
        else { return }
        request(.resize(serial: serial, edges: edges), replan: false)
    }

    func setMaxSize(_ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32) {
        guard width >= 0, height >= 0,
            (width == 0 || width >= minWidth),
            (height == 0 || height >= minHeight)
        else {
            WaylandProtocolError(
                resource,
                XdgToplevelProtocolError.invalidSize,
                "maximum size conflicts with minimum size"
            ).post()
            return
        }
        maxWidth = width
        maxHeight = height
        request(.setMaxSize(width: width, height: height), replan: false)
    }

    func setMinSize(_ resource: UnsafeMutablePointer<wl_resource>, width: Int32, height: Int32) {
        guard width >= 0, height >= 0,
            (maxWidth == 0 || width <= maxWidth),
            (maxHeight == 0 || height <= maxHeight)
        else {
            WaylandProtocolError(
                resource,
                XdgToplevelProtocolError.invalidSize,
                "minimum size conflicts with maximum size"
            ).post()
            return
        }
        minWidth = width
        minHeight = height
        request(.setMinSize(width: width, height: height), replan: false)
    }

    func setMaximized(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setMaximized(true), replan: true)
    }

    func unsetMaximized(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setMaximized(false), replan: true)
    }

    func setFullscreen(
        _ resource: UnsafeMutablePointer<wl_resource>, output: UnsafeMutablePointer<wl_resource>?
    ) {
        request(
            .setFullscreen(
                true, outputID: WlOutput.from(output)?.outputId),
            replan: true)
    }

    func unsetFullscreen(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setFullscreen(false, outputID: nil), replan: true)
    }

    func setMinimized(_ resource: UnsafeMutablePointer<wl_resource>) {
        request(.setMinimized, replan: false)
    }
}

// MARK: - xdg_popup

/// A popup role: positioned relative to its parent at creation, mapped on first
/// commit. Grab routing, outside/Escape dismissal, and reposition are driven by
/// the live seat and output topology.
