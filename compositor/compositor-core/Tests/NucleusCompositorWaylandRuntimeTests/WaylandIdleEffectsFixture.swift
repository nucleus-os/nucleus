// Parity fixture for the idle and surface-effect protocols on the router:
//   - idle-inhibit + ext-idle-notify: an inhibitor suppresses a regular idle
//     notification but not an input-only one; removing the inhibitor lets the
//     regular one idle; user input resumes both. The idle clock is driven directly
//     (idleTick / noteUserInput stand in for the reactor's monotonic timer).
//   - kde-blur: set_region + commit publishes the blur region; unset clears it.
//   - ext-background-effect: capabilities is advertised on bind; set_blur_region
//     latches and publishes on the surface's commit.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private final class EffectsDelegate: KdeBlurDelegate, BackgroundEffectDelegate {
    var blurOps: Int?
    var blurWhole: Bool?
    var blurCleared = false
    var bgOps: Int??

    func kdeBlurUpdated(_ surface: WlSurface, region: RegionSnapshot?, wholeSurface: Bool) {
        blurOps = region?.rectangleCount ?? 0
        blurWhole = wholeSurface
    }
    func kdeBlurCleared(_ surface: WlSurface) { blurCleared = true }
    func backgroundBlurRegionUpdated(_ surface: WlSurface, region: RegionSnapshot?) {
        bgOps = .some(region?.rectangleCount)
    }
}

@main
enum WaylandIdleEffectsFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let delegate = EffectsDelegate()
        let compositor = WlCompositor(); compositor.register(in: router)
        let seat = WlSeat(); seat.register(in: router)
        let idle = IdleManager(); idle.register(in: router)
        let blur = OrgKdeKwinBlurManager(); blur.delegate = delegate; blur.register(in: router)
        let bg = ExtBackgroundEffectManager(); bg.delegate = delegate; bg.register(in: router)

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

        let compId: UInt32 = 3, inhibitMgr: UInt32 = 4, notifierMgr: UInt32 = 5
        let blurMgr: UInt32 = 6, bgMgr: UInt32 = 7, seatId: UInt32 = 8
        let surfId: UInt32 = 9, regId: UInt32 = 10, inhibitId: UInt32 = 11
        let notifReg: UInt32 = 12, notifInput: UInt32 = 13, blurId: UInt32 = 14, bgId: UInt32 = 15

        // Setup + inhibitor + both notifications.
        var a = WireBuilder()
        bind(&a, "wl_compositor", compId)
        bind(&a, "zwp_idle_inhibit_manager_v1", inhibitMgr)
        bind(&a, "ext_idle_notifier_v1", notifierMgr)
        bind(&a, "org_kde_kwin_blur_manager", blurMgr)
        bind(&a, "ext_background_effect_manager_v1", bgMgr)
        bind(&a, "wl_seat", seatId)
        a.message(object: compId, opcode: 0) { $0.newId(surfId) }                   // create_surface
        a.message(object: compId, opcode: 1) { $0.newId(regId) }                    // create_region
        a.message(object: regId, opcode: 1) { $0.int(0); $0.int(0); $0.int(100); $0.int(50) }  // add
        a.message(object: inhibitMgr, opcode: 1) { $0.newId(inhibitId); $0.object(surfId) }  // create_inhibitor
        a.message(object: notifierMgr, opcode: 1) { $0.newId(notifReg); $0.uint(1000); $0.object(seatId) }  // get_idle_notification
        a.message(object: notifierMgr, opcode: 2) { $0.newId(notifInput); $0.uint(500); $0.object(seatId) }  // get_input_idle_notification
        guard client.send(a) else { fail("send a") }
        client.pump()
        let rA = client.drainEvents()
        guard let caps = WireMessage.first(rA, object: bgMgr, opcode: 0), caps.u32(0) == 1 else {
            fail("background-effect capabilities != 1")
        }
        guard idle.inhibitorCount == 1 else { fail("inhibitorCount=\(idle.inhibitorCount)") }

        // Tick past both deadlines while inhibited: the regular notification is
        // suppressed; the input-only one idles.
        idle.idleTick(nowMs: 2000)
        let r1 = client.drainEvents()
        let regIdledWhileInhibited = WireMessage.first(r1, object: notifReg, opcode: 0) != nil
        let inputIdled = WireMessage.first(r1, object: notifInput, opcode: 0) != nil
        guard !regIdledWhileInhibited else { fail("regular notification idled while inhibited") }
        guard inputIdled else { fail("input-only notification did not idle") }

        // Drop the inhibitor, then tick: the regular notification now idles.
        var b = WireBuilder()
        b.message(object: inhibitId, opcode: 0) { _ in }  // inhibitor.destroy
        guard client.send(b) else { fail("send b") }
        client.pump()
        guard idle.inhibitorCount == 0 else { fail("inhibitorCount after destroy=\(idle.inhibitorCount)") }
        idle.idleTick(nowMs: 3000)
        let r2 = client.drainEvents()
        guard WireMessage.first(r2, object: notifReg, opcode: 0) != nil else {
            fail("regular notification did not idle after uninhibit")
        }

        // User input resumes both idled notifications.
        idle.noteUserInput(atMs: 3500)
        let r3 = client.drainEvents()
        let resumedReg = WireMessage.first(r3, object: notifReg, opcode: 1) != nil
        let resumedInput = WireMessage.first(r3, object: notifInput, opcode: 1) != nil
        let resumedCount = (resumedReg ? 1 : 0) + (resumedInput ? 1 : 0)
        guard resumedCount == 2 else { fail("resumed=\(resumedCount)") }

        // kde-blur: set_region + commit publishes; unset clears.
        var c = WireBuilder()
        c.message(object: blurMgr, opcode: 0) { $0.newId(blurId); $0.object(surfId) }  // create
        c.message(object: blurId, opcode: 1) { $0.object(regId) }                      // set_region
        c.message(object: blurId, opcode: 0) { _ in }                                  // commit
        guard client.send(c) else { fail("send c") }
        client.pump()
        guard delegate.blurOps == 1, delegate.blurWhole == false else {
            fail("kde-blur ops=\(String(describing: delegate.blurOps)) whole=\(String(describing: delegate.blurWhole))")
        }
        var d = WireBuilder()
        d.message(object: blurMgr, opcode: 1) { $0.object(surfId) }  // unset
        guard client.send(d) else { fail("send d") }
        client.pump()
        guard delegate.blurCleared else { fail("kde-blur not cleared") }

        // ext-background-effect: set_blur_region latches and publishes on commit.
        var e = WireBuilder()
        e.message(object: bgMgr, opcode: 1) { $0.newId(bgId); $0.object(surfId) }  // get_background_effect
        e.message(object: bgId, opcode: 1) { $0.object(regId) }                    // set_blur_region
        e.message(object: surfId, opcode: 6) { _ in }                              // wl_surface.commit
        guard client.send(e) else { fail("send e") }
        client.pump()
        guard case .some(.some(1)) = delegate.bgOps else {
            fail("background-effect ops=\(String(describing: delegate.bgOps))")
        }

        print("OK wayland idle-effects bg_caps=1 inhibit_suppressed=1 input_idle=1 "
            + "idle_after_uninhibit=1 resumed=\(resumedCount) blur_ops=1 blur_cleared=1 bg_ops=1")
    }
}
