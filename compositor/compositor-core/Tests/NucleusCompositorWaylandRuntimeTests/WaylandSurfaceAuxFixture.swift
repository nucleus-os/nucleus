// Parity fixture for the surface-adjacent state protocols on the router:
//   - viewporter: set_source (fixed) / set_destination latch into the surface
//     transaction (asserted via the scene-delegate commit).
//   - fractional-scale: get_fractional_scale sends the preferred scale, and a
//     dynamic preferred-scale change is pushed (deduped) to the bound object.
//   - tearing-control: set_presentation_hint latches the surface's present hint.
//   - commit-timing: set_timestamp latches the surface's target present time.
//   - fifo: set_barrier / wait_barrier latch the surface's per-commit FIFO flags.
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
        WpTearingControlManager().register(in: router)
        WpCommitTimingManager().register(in: router)
        WpFifoManager().register(in: router)

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
        let tcMgr: UInt32 = 6, ctMgr: UInt32 = 7, fifoMgr: UInt32 = 8
        let surfId: UInt32 = 9
        // Objects minted in creation order (no id gaps): fractional 10, then the
        // viewport/tearing/timer/fifo objects 11..14.
        let fsId: UInt32 = 10, vpId: UInt32 = 11, tcId: UInt32 = 12, ctId: UInt32 = 13, fifoId: UInt32 = 14

        // Step A: bind globals, create the surface, commit once (initial) so the
        // scene captures the WlSurface.
        var a = WireBuilder()
        bind(&a, "wl_compositor", compId)
        bind(&a, "wp_viewporter", vpMgr)
        bind(&a, "wp_fractional_scale_manager_v1", fsMgr)
        bind(&a, "wp_tearing_control_manager_v1", tcMgr)
        bind(&a, "wp_commit_timing_manager_v1", ctMgr)
        bind(&a, "wp_fifo_manager_v1", fifoMgr)
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

        // Step C: viewport / tearing / timing / fifo, then one commit that latches
        // all of it into a single transaction. Fixed args are sent as raw wl_fixed
        // (value × 256).
        func fixed(_ v: Int32) -> Int32 { v * 256 }
        var c = WireBuilder()
        c.message(object: vpMgr, opcode: 1) { $0.newId(vpId); $0.object(surfId) }   // get_viewport
        c.message(object: vpId, opcode: 1) {                                        // set_source 10,20,300,200
            $0.int(fixed(10)); $0.int(fixed(20)); $0.int(fixed(300)); $0.int(fixed(200))
        }
        c.message(object: vpId, opcode: 2) { $0.int(1280); $0.int(720) }            // set_destination
        c.message(object: tcMgr, opcode: 1) { $0.newId(tcId); $0.object(surfId) }   // get_tearing_control
        c.message(object: tcId, opcode: 0) { $0.uint(1) }                           // set_presentation_hint(async)
        c.message(object: ctMgr, opcode: 1) { $0.newId(ctId); $0.object(surfId) }   // get_timer
        c.message(object: ctId, opcode: 0) { $0.uint(0); $0.uint(5); $0.uint(500) } // set_timestamp 5s + 500ns
        c.message(object: fifoMgr, opcode: 1) { $0.newId(fifoId); $0.object(surfId) }  // get_fifo
        c.message(object: fifoId, opcode: 0) { _ in }                               // set_barrier
        c.message(object: fifoId, opcode: 1) { _ in }                               // wait_barrier
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
        guard aux.presentationHint == 1 else { fail("present hint=\(aux.presentationHint)") }
        guard aux.commitTimestampNs == 5_000_000_500 else {
            fail("commit ts=\(String(describing: aux.commitTimestampNs))")
        }
        guard aux.fifoBarrier, aux.fifoWaitBarrier else {
            fail("fifo=\(aux.fifoBarrier),\(aux.fifoWaitBarrier)")
        }

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
            + "viewport_dst=\(dst.width)x\(dst.height) hint=\(aux.presentationHint) "
            + "commit_ts=\(aux.commitTimestampNs!) fifo=\(aux.fifoBarrier ? 1 : 0),\(aux.fifoWaitBarrier ? 1 : 0) "
            + "frac=120,240 bad_value=1")
    }
}
