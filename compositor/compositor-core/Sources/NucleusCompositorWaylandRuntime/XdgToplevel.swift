// ConfigurePolicy by the production router.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes
internal import NucleusCompositorWindowManager

@MainActor
@safe final class XdgToplevel {
    let id: XdgToplevelID
    unowned let shell: XdgShell
    weak var xdgSurface: XdgSurface?
    private let resource: WaylandResourceHandle<XdgToplevelServer>
    /// The most recent window geometry the surface declared (visible content rect).
    var windowGeometry: WlRect? { xdgSurface?.windowGeometry }
    private var minWidth: Int32 = 0
    private var minHeight: Int32 = 0
    private var maxWidth: Int32 = 0
    private var maxHeight: Int32 = 0
    weak var protocolParent: XdgToplevel?
    weak var decoration: XdgToplevelDecoration?
    var isMapped: Bool { xdgSurface?.isMapped == true }

    init(
        resource: WaylandResourceHandle<XdgToplevelServer>,
        shell: XdgShell,
        xdgSurface: XdgSurface
    ) {
        self.resource = resource
        self.id = shell.mintToplevelID()
        self.shell = shell
        self.xdgSurface = xdgSurface
    }

    package func installed() {
        shell.registerToplevel(self)
    }

    /// Send xdg_toplevel.configure(width, height, states) — the states serialized
    /// into the configure's wl_array as little-endian u32s.
    func sendConfigure(_ plan: XdgToplevelConfigure) {
        resource.sendConfigure(
            width: plan.width,
            height: plan.height,
            states: plan.states)
    }

    /// Ask the client to close (xdg_toplevel.close).
    func sendClose() {
        resource.sendClose()
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

    isolated deinit {
        shell.toplevelDidUnmap(self)
        shell.unregisterToplevel(self)
        xdgSurface?.roleObjectDestroyed(self)
        shell.delegate?.toplevelWillDestroy(self)
    }
}

extension XdgToplevel: XdgToplevelRequests {
    func destroy(_ context: WaylandRequest<XdgToplevelServer>) {
        let resource = unsafe context.resource
        shell.toplevelDidUnmap(self)
        xdgSurface?.roleObjectDestroyed(self)
        unsafe wl_resource_destroy(resource)
    }

    func setParent(
        _ context: WaylandRequest<XdgToplevelServer>, parent parentRes: WaylandBorrowedObject<XdgToplevelServer>?
    ) {
        let requested = parentRes?.owner(as: XdgToplevel.self)
        if let requested, requested === self || wouldCreateParentCycle(requested) {
            context.postError(
                .invalidParent,
                message: "parent must not be the toplevel or one of its descendants")
            return
        }
        applyProtocolParent(requested?.isMapped == true ? requested : nil)
    }

    func setTitle(_ context: WaylandRequest<XdgToplevelServer>, title: String) {
        request(
            .setTitle(title),
            replan: false)
    }

    func setAppId(_ context: WaylandRequest<XdgToplevelServer>, app_id: String) {
        request(
            .setAppId(app_id),
            replan: false)
    }

    func showWindowMenu(
        _ context: WaylandRequest<XdgToplevelServer>, seat: WaylandBorrowedObject<WlSeatServer>,
        serial: UInt32, x: Int32, y: Int32
    ) {
        guard unsafe shell.delegate?.authorizeInteractiveRequest(
            self, seat: seat.resource, serial: serial) == true
        else { return }
        request(.showWindowMenu(serial: serial, x: x, y: y), replan: false)
    }

    func move(
        _ context: WaylandRequest<XdgToplevelServer>, seat: WaylandBorrowedObject<WlSeatServer>, serial: UInt32
    ) {
        guard unsafe shell.delegate?.authorizeInteractiveRequest(
            self, seat: seat.resource, serial: serial) == true
        else { return }
        request(.move(serial: serial), replan: false)
    }

    func resize(
        _ context: WaylandRequest<XdgToplevelServer>, seat: WaylandBorrowedObject<WlSeatServer>,
        serial: UInt32, edges: XdgToplevelResizeEdge
    ) {
        let validEdges: Set<UInt32> = [1, 2, 4, 5, 6, 8, 9, 10]
        guard validEdges.contains(edges.rawValue) else {
            context.postError(
                .invalidResizeEdge,
                message: "invalid resize edge")
            return
        }
        guard unsafe shell.delegate?.authorizeInteractiveRequest(
            self, seat: seat.resource, serial: serial) == true
        else { return }
        request(.resize(serial: serial, edges: edges.rawValue), replan: false)
    }

    func setMaxSize(_ context: WaylandRequest<XdgToplevelServer>, width: Int32, height: Int32) {
        guard width >= 0, height >= 0,
            (width == 0 || width >= minWidth),
            (height == 0 || height >= minHeight)
        else {
            context.postError(
                .invalidSize,
                message: "maximum size conflicts with minimum size")
            return
        }
        maxWidth = width
        maxHeight = height
        request(.setMaxSize(width: width, height: height), replan: false)
    }

    func setMinSize(_ context: WaylandRequest<XdgToplevelServer>, width: Int32, height: Int32) {
        guard width >= 0, height >= 0,
            (maxWidth == 0 || width <= maxWidth),
            (maxHeight == 0 || height <= maxHeight)
        else {
            context.postError(
                .invalidSize,
                message: "minimum size conflicts with maximum size")
            return
        }
        minWidth = width
        minHeight = height
        request(.setMinSize(width: width, height: height), replan: false)
    }

    func setMaximized(_ context: WaylandRequest<XdgToplevelServer>) {
        request(.setMaximized(true), replan: true)
    }

    func unsetMaximized(_ context: WaylandRequest<XdgToplevelServer>) {
        request(.setMaximized(false), replan: true)
    }

    func setFullscreen(
        _ context: WaylandRequest<XdgToplevelServer>, output: WaylandBorrowedObject<WlOutputServer>?
    ) {
        request(
            .setFullscreen(
                true, outputID: output?.output?.outputId),
            replan: true)
    }

    func unsetFullscreen(_ context: WaylandRequest<XdgToplevelServer>) {
        request(.setFullscreen(false, outputID: nil), replan: true)
    }

    func setMinimized(_ context: WaylandRequest<XdgToplevelServer>) {
        request(.setMinimized, replan: false)
    }
}

// MARK: - xdg_popup

/// A popup role: positioned relative to its parent at creation, mapped on first
/// commit. Grab routing, outside/Escape dismissal, and reposition are driven by
/// the live seat and output topology.
