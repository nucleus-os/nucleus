// Parity fixture for the wl_surface transaction model. Drives a real client
// through create_surface / create_region / region.add / set_opaque_region /
// set_buffer_scale / damage / frame / commit, triggers a presentation tick, and
// asserts both the wire-visible behaviour (preferred_buffer_scale, frame-callback
// done) and the scene-delegate observation of the committed transaction.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

/// Records the surface commits the compositor reports — stands in for the scene
/// at #12, here used to assert the latched transaction.
private final class RecordingScene: SurfaceSceneDelegate {
    var commits: [SurfaceCommit] = []
    var destroyed = 0
    func surfaceCommitted(_ surface: WlSurface, _ commit: SurfaceCommit) { commits.append(commit) }
    func surfaceDestroyed(_ surface: WlSurface) { destroyed += 1 }
}

@main
enum WaylandSurfaceFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let compositor = WlCompositor()
        compositor.preferredBufferScale = 2
        let scene = RecordingScene()
        compositor.sceneDelegate = scene
        compositor.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        guard let comp = globals.first(where: { $0.interface == "wl_compositor" }) else {
            fail("wl_compositor not advertised")
        }

        // Sequential ids after the registry (2): compositor 3, surface 4, region 5,
        // frame callback 6.
        let compId: UInt32 = 3, surfId: UInt32 = 4, regId: UInt32 = 5, cbId: UInt32 = 6
        let frameTime: UInt32 = 12_345

        var req = WireBuilder()
        req.message(object: 2, opcode: 0) {  // wl_registry.bind(wl_compositor)
            $0.uint(comp.name); $0.string("wl_compositor"); $0.uint(comp.version); $0.newId(compId)
        }
        req.message(object: compId, opcode: 0) { $0.newId(surfId) }  // create_surface
        req.message(object: compId, opcode: 1) { $0.newId(regId) }   // create_region
        req.message(object: regId, opcode: 1) {                       // wl_region.add
            $0.int(0); $0.int(0); $0.int(100); $0.int(50)
        }
        req.message(object: surfId, opcode: 4) { $0.object(regId) }   // set_opaque_region
        req.message(object: surfId, opcode: 8) { $0.int(2) }          // set_buffer_scale
        req.message(object: surfId, opcode: 2) {                       // damage
            $0.int(0); $0.int(0); $0.int(640); $0.int(480)
        }
        req.message(object: surfId, opcode: 3) { $0.newId(cbId) }     // frame
        req.message(object: surfId, opcode: 6) { _ in }               // commit
        guard client.send(req) else { fail("send") }
        client.pump()

        // Presentation tick completes the frame callback.
        compositor.present(timeMs: frameTime)
        let events = client.drainEvents()

        // Scene observed exactly one commit with the latched state.
        guard scene.commits.count == 1 else { fail("commits=\(scene.commits.count)") }
        let c = scene.commits[0]
        guard c.bufferScale == 2 else { fail("commit scale=\(c.bufferScale)") }
        guard c.surfaceDamage.count == 1,
            c.surfaceDamage[0] == WlRect(x: 0, y: 0, width: 640, height: 480)
        else { fail("commit damage=\(c.surfaceDamage)") }
        let opaqueOps = c.opaqueRegion?.rectangleCount ?? 0
        guard opaqueOps == 1 else { fail("opaque ops=\(opaqueOps)") }
        guard c.isInitialCommit else { fail("not initial commit") }

        // Wire: preferred_buffer_scale (object surfId, opcode 2) at creation.
        guard let scale = WireMessage.first(events, object: surfId, opcode: 2) else {
            fail("preferred_buffer_scale missing")
        }
        guard scale.i32(0) == 2 else { fail("preferred scale=\(scale.i32(0))") }
        // Wire: wl_callback.done (object cbId, opcode 0) carrying the present time.
        guard let done = WireMessage.first(events, object: cbId, opcode: 0) else {
            fail("frame callback done missing")
        }
        guard done.u32(0) == frameTime else { fail("frame done time=\(done.u32(0))") }

        print("OK wayland surface commits=\(scene.commits.count) scale=\(c.bufferScale) "
            + "damage=\(c.surfaceDamage.count) opaque_ops=\(opaqueOps) frame_done=\(done.u32(0))")
    }
}
