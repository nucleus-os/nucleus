// Parity fixture for wp_presentation on the router: the clock domain is advertised
// on bind; a feedback registered for a committed surface receives `presented` with
// the presentation timing when the render path presents it; a feedback for content
// that is never presented (the surface is destroyed) receives `discarded`.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private final class RecordingScene: SurfaceSceneDelegate {
    var lastSurface: WlSurface?
    func surfaceCommitted(_ surface: WlSurface, _ commit: SurfaceCommit) { lastSurface = surface }
    func surfaceDestroyed(_ surface: WlSurface) {}
}

@main
enum WaylandPresentationFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let scene = RecordingScene()
        let compositor = WlCompositor()
        compositor.sceneDelegate = scene
        compositor.register(in: router)
        WpPresentation().register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        func g(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let v = globals.first(where: { $0.interface == iface }) else { fail("no \(iface)") }
            return (v.name, v.version)
        }
        func bind(_ b: inout WireBuilder, _ iface: String, _ id: UInt32) {
            let info = g(iface)
            b.message(object: 2, opcode: 0) {
                $0.uint(info.name); $0.string(iface); $0.uint(info.version); $0.newId(id)
            }
        }

        let compId: UInt32 = 3, presId: UInt32 = 4, surfId: UInt32 = 5
        let fb1: UInt32 = 6, fb2: UInt32 = 7

        // Bind: clock_id is advertised on the wp_presentation resource.
        var a = WireBuilder()
        bind(&a, "wl_compositor", compId)
        bind(&a, "wp_presentation", presId)
        guard client.send(a) else { fail("send a") }
        client.pump()
        let rA = client.drainEvents()
        guard let clk = WireMessage.first(rA, object: presId, opcode: 0), clk.u32(0) == 1 else {
            fail("clock_id != CLOCK_MONOTONIC")
        }

        // Register a feedback for a committed surface, then present it.
        var b = WireBuilder()
        b.message(object: compId, opcode: 0) { $0.newId(surfId) }                  // create_surface
        b.message(object: presId, opcode: 1) { $0.object(surfId); $0.newId(fb1) }   // feedback
        b.message(object: surfId, opcode: 6) { _ in }                              // commit
        guard client.send(b) else { fail("send b") }
        client.pump()
        _ = client.drainEvents()
        // Present through the optional so no lingering strong ref keeps the surface
        // alive past its destroy (which must deinit to fire `discarded`).
        guard scene.lastSurface != nil else { fail("no surface") }
        scene.lastSurface?.presentFeedback(
            tvSecHi: 0, tvSecLo: 7, tvNsec: 123, refreshNs: 16_666_666, seqHi: 0, seqLo: 42, flags: 0xf)
        let rP = client.drainEvents()
        guard let p = WireMessage.first(rP, object: fb1, opcode: 1) else { fail("no presented") }
        guard p.u32(0) == 0, p.u32(4) == 7, p.u32(8) == 123, p.u32(12) == 16_666_666,
            p.u32(16) == 0, p.u32(20) == 42, p.u32(24) == 0xf
        else { fail("presented args wrong") }

        // Register a feedback, commit, then destroy the surface without presenting:
        // the feedback is discarded.
        var c = WireBuilder()
        c.message(object: presId, opcode: 1) { $0.object(surfId); $0.newId(fb2) }   // feedback
        c.message(object: surfId, opcode: 6) { _ in }                              // commit
        guard client.send(c) else { fail("send c") }
        client.pump()
        _ = client.drainEvents()
        // Drop the only non-resource strong ref so destroying the resource deinits
        // the surface (firing discarded for the un-presented feedback).
        scene.lastSurface = nil
        var d = WireBuilder()
        d.message(object: surfId, opcode: 0) { _ in }  // wl_surface.destroy
        guard client.send(d) else { fail("send d") }
        client.pump()
        let rD = client.drainEvents()
        guard WireMessage.first(rD, object: fb2, opcode: 2) != nil else { fail("no discarded") }

        print("OK wayland presentation clock_id=1 "
            + "presented=\(p.u32(4))s.\(p.u32(8))ns,refresh=\(p.u32(12)),seq=\(p.u32(20)),flags=\(p.u32(24)) "
            + "discarded=1")
    }
}
