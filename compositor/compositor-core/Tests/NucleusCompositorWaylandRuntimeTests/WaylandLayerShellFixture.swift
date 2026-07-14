// Parity fixture for wlr-layer-shell-unstable-v1 on the router. A panel anchored
// top|left|right with height 30 against a 1920×1080 output should configure to the
// full output width × 30 at the top-left; ack + commit maps it; closed asks the
// client to tear down. Then an xdg popup created with no parent is adopted by the
// layer surface via get_popup and re-configured (the cross-global resolution that
// libwayland gives for free — the retired XdgWmBaseTable lookup is gone).

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private final class StubLayerDelegate: LayerShellDelegate {
    var mappedNamespace: String?
    func layerSurfaceMapped(_ surface: ZwlrLayerSurface) { mappedNamespace = surface.namespace }
}

@main
enum WaylandLayerShellFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let compositor = WlCompositor()
        compositor.register(in: router)
        let output = WlOutput(info: OutputInfo(
            physicalWidthMm: 600, physicalHeightMm: 340,
            pixelWidth: 1920, pixelHeight: 1080, refreshMhz: 60000, scale: 1,
            name: "DP-1", description: "Virtual Output"))
        output.register(in: router)
        let layerShell = ZwlrLayerShell()
        let layerDelegate = StubLayerDelegate()
        layerShell.delegate = layerDelegate
        layerShell.register(in: router)
        let xdg = XdgShell()
        xdg.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        func name(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let g = globals.first(where: { $0.interface == iface }) else { fail("no \(iface)") }
            return (g.name, g.version)
        }
        let lsG = name("zwlr_layer_shell_v1")
        let compG = name("wl_compositor")
        let outG = name("wl_output")
        let wmG = name("xdg_wm_base")

        // ids: layer_shell 3, compositor 4, output 5, wm_base 6, surface 7, layer_surface 8.
        let lsId: UInt32 = 3, compId: UInt32 = 4, outId: UInt32 = 5, wmId: UInt32 = 6
        let surfId: UInt32 = 7, layerId: UInt32 = 8

        var a = WireBuilder()
        a.message(object: 2, opcode: 0) {  // bind zwlr_layer_shell_v1
            $0.uint(lsG.name); $0.string("zwlr_layer_shell_v1"); $0.uint(lsG.version); $0.newId(lsId)
        }
        a.message(object: 2, opcode: 0) {  // bind wl_compositor
            $0.uint(compG.name); $0.string("wl_compositor"); $0.uint(compG.version); $0.newId(compId)
        }
        a.message(object: 2, opcode: 0) {  // bind wl_output
            $0.uint(outG.name); $0.string("wl_output"); $0.uint(outG.version); $0.newId(outId)
        }
        a.message(object: 2, opcode: 0) {  // bind xdg_wm_base
            $0.uint(wmG.name); $0.string("xdg_wm_base"); $0.uint(wmG.version); $0.newId(wmId)
        }
        a.message(object: compId, opcode: 0) { $0.newId(surfId) }  // create_surface
        // get_layer_surface(id, surface, output, layer=top(2), namespace="panel")
        a.message(object: lsId, opcode: 0) {
            $0.newId(layerId); $0.object(surfId); $0.object(outId); $0.uint(2); $0.string("panel")
        }
        a.message(object: layerId, opcode: 1) { $0.uint(1 | 4 | 8) }  // set_anchor top|left|right
        a.message(object: layerId, opcode: 0) { $0.uint(0); $0.uint(30) }  // set_size (fill x, 30 tall)
        a.message(object: layerId, opcode: 2) { $0.int(30) }  // set_exclusive_zone
        a.message(object: layerId, opcode: 3) { $0.int(0); $0.int(0); $0.int(0); $0.int(0) }  // set_margin
        a.message(object: surfId, opcode: 6) { _ in }  // commit → initial configure
        guard client.send(a) else { fail("send a") }
        client.pump()
        let afterCommit = client.drainEvents()

        guard let conf = WireMessage.first(afterCommit, object: layerId, opcode: 0) else {
            fail("missing layer_surface.configure")
        }
        let serial = conf.u32(0)
        let cw = conf.u32(4), ch = conf.u32(8)
        guard cw == 1920, ch == 30 else { fail("arranged size \(cw)×\(ch) != 1920×30") }

        // ack + commit → map.
        var b = WireBuilder()
        b.message(object: layerId, opcode: 6) { $0.uint(serial) }  // ack_configure
        b.message(object: surfId, opcode: 6) { _ in }              // commit → map
        guard client.send(b) else { fail("send b") }
        client.pump()
        _ = client.drainEvents()
        guard layerDelegate.mappedNamespace == "panel" else { fail("layer surface not mapped") }

        // Popup adoption: an xdg popup with no parent, then layer_surface.get_popup.
        // ids: positioner 9, popup_surface 10, popup_xdg_surface 11, popup 12.
        let posId: UInt32 = 9, psurfId: UInt32 = 10, pxdgId: UInt32 = 11, popId: UInt32 = 12
        var c = WireBuilder()
        c.message(object: wmId, opcode: 1) { $0.newId(posId) }                    // create_positioner
        c.message(object: posId, opcode: 1) { $0.int(100); $0.int(50) }           // set_size
        c.message(object: posId, opcode: 2) { $0.int(0); $0.int(0); $0.int(10); $0.int(10) }  // set_anchor_rect
        c.message(object: compId, opcode: 0) { $0.newId(psurfId) }                // create_surface
        c.message(object: wmId, opcode: 2) { $0.newId(pxdgId); $0.object(psurfId) }  // get_xdg_surface
        c.message(object: pxdgId, opcode: 2) {                                    // get_popup(id, parent=null, positioner)
            $0.newId(popId); $0.object(0); $0.object(posId)
        }
        guard client.send(c) else { fail("send c") }
        client.pump()
        let afterPopupCreate = client.drainEvents()
        guard WireMessage.first(afterPopupCreate, object: popId, opcode: 0) != nil else {
            fail("missing popup initial configure")
        }

        // Adopt the popup onto the layer surface → it is re-configured.
        var d = WireBuilder()
        d.message(object: layerId, opcode: 5) { $0.object(popId) }  // layer_surface.get_popup
        guard client.send(d) else { fail("send d") }
        client.pump()
        let afterAdopt = client.drainEvents()
        guard WireMessage.first(afterAdopt, object: popId, opcode: 0) != nil else {
            fail("popup not re-configured on layer adoption")
        }

        // closed asks the client to destroy the surface (compositor-initiated).
        compositor.surface(id: surfId)?.role.flatMap { $0 as? ZwlrLayerSurface }?.sendClosed()
        let afterClosed = client.drainEvents()
        guard WireMessage.first(afterClosed, object: layerId, opcode: 1) != nil else {
            fail("missing layer_surface.closed")
        }

        print("OK wayland layer-shell configure=1920x30 mapped=panel popup_adopted=1 closed=1")
    }
}
