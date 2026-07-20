// Parity fixture for the surface-adjacent state protocols on the router:
//   - viewporter: set_source (fixed) / set_destination latch into the surface
//     transaction (asserted via the scene-delegate commit).
//   - fractional-scale: get_fractional_scale sends the preferred scale, and a
//     dynamic preferred-scale change is pushed (deduped) to the bound object.
//   - viewporter bad_value: a negative source rectangle raises the protocol error
//     (sent last — it disconnects the client).

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

/// Captures the latched commits and the committing surface (the surface ref lets
/// the fixture drive the output-affinity fractional-scale push directly).
private final class RecordingScene: SurfaceSceneDelegate {
    var commits: [SurfaceCommit] = []
    var lastSurface: WlSurface?
    func surfaceCommitted(_ surface: WlSurface, _ commit: SurfaceCommit) {
        lastSurface = surface
        commits.append(commit)
    }
    func surfaceDestroyed(_ surface: WlSurface) {}
}

@main
enum WaylandSurfaceAuxFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let scene = RecordingScene()
        let compositor = WlCompositor()
        compositor.sceneDelegate = scene
        compositor.register(in: router)
        WpViewporter().register(in: router)
        WpFractionalScaleManager().register(in: router)

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

        let compId: UInt32 = 3, vpMgr: UInt32 = 4, fsMgr: UInt32 = 5
        let surfId: UInt32 = 6
        // Objects minted in creation order (no id gaps): fractional 7, then the
        // viewport object 8.
        let fsId: UInt32 = 7, vpId: UInt32 = 8

        // Step A: bind globals, create the surface, commit once (initial) so the
        // scene captures the WlSurface.
        var a = WireBuilder()
        bind(&a, "wl_compositor", compId)
        bind(&a, "wp_viewporter", vpMgr)
        bind(&a, "wp_fractional_scale_manager_v1", fsMgr)
        a.message(object: compId, opcode: 0) { $0.newId(surfId) }  // create_surface
        a.message(object: surfId, opcode: 6) { _ in }              // commit (initial)
        guard client.send(a) else { fail("send a") }
        client.pump()
        _ = client.drainEvents()
        guard let surface = scene.lastSurface else { fail("no surface captured") }

        // Step B: fractional-scale. get_fractional_scale sends the default 120;
        // pushing a new preferred scale delivers it, a repeat is deduped, a change
        // delivers again.
        var b = WireBuilder()
        b.message(object: fsMgr, opcode: 1) { $0.newId(fsId); $0.object(surfId) }  // get_fractional_scale
        guard client.send(b) else { fail("send b") }
        client.pump()
        let rB = client.drainEvents()
        guard let s0 = WireMessage.first(rB, object: fsId, opcode: 0), s0.u32(0) == 120 else {
            fail("fractional initial preferred_scale != 120")
        }
        surface.setPreferredFractionalScale(180)
        guard let s1 = WireMessage.first(client.drainEvents(), object: fsId, opcode: 0), s1.u32(0) == 180
        else { fail("fractional preferred_scale push != 180") }
        surface.setPreferredFractionalScale(180)  // duplicate: no event
        guard WireMessage.first(client.drainEvents(), object: fsId, opcode: 0) == nil else {
            fail("fractional duplicate scale not deduped")
        }
        surface.setPreferredFractionalScale(240)
        guard let s2 = WireMessage.first(client.drainEvents(), object: fsId, opcode: 0), s2.u32(0) == 240
        else { fail("fractional preferred_scale change != 240") }

        // Step C: viewport state, followed by one commit that latches the
        // transaction. Fixed args are sent as raw wl_fixed (value × 256).
        func fixed(_ v: Int32) -> Int32 { v * 256 }
        var c = WireBuilder()
        c.message(object: vpMgr, opcode: 1) { $0.newId(vpId); $0.object(surfId) }   // get_viewport
        c.message(object: vpId, opcode: 1) {                                        // set_source 10,20,300,200
            $0.int(fixed(10)); $0.int(fixed(20)); $0.int(fixed(300)); $0.int(fixed(200))
        }
        c.message(object: vpId, opcode: 2) { $0.int(1280); $0.int(720) }            // set_destination
        c.message(object: surfId, opcode: 6) { _ in }                               // commit
        guard client.send(c) else { fail("send c") }
        client.pump()
        _ = client.drainEvents()

        guard scene.commits.count == 2 else { fail("commits=\(scene.commits.count)") }
        let aux = scene.commits[1].aux
        guard let src = aux.viewportSource,
            src == WlFRect(x: 10, y: 20, width: 300, height: 200)
        else { fail("viewport source=\(String(describing: aux.viewportSource))") }
        guard let dst = aux.viewportDestination, dst == WlSize(width: 1280, height: 720)
        else { fail("viewport destination=\(String(describing: aux.viewportDestination))") }

        // Step D (last): a negative source rectangle is bad_value (disconnects).
        var d = WireBuilder()
        d.message(object: vpId, opcode: 1) {  // set_source(-1.0, 0, 1, 1)
            $0.int(fixed(-1)); $0.int(0); $0.int(fixed(1)); $0.int(fixed(1))
        }
        guard client.send(d) else { fail("send d") }
        client.pump()
        let rD = client.drainEvents()
        guard let err = WireMessage.first(rD, object: 1, opcode: 0),
            err.u32(0) == vpId, err.u32(4) == 0 else { fail("missing viewport bad_value error") }

        print("OK wayland surface-aux viewport_src=\(Int(src.x)),\(Int(src.y)),\(Int(src.width)),\(Int(src.height)) "
            + "viewport_dst=\(dst.width)x\(dst.height) "
            + "frac=120,240 bad_value=1")
    }
}
