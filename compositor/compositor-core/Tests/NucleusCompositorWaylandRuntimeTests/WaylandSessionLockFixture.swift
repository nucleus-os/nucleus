// Parity fixture for ext_session_lock_manager_v1 on the router: a lock is granted
// (arming the security-gate delegate) while a concurrent second lock is denied with
// finished; a lock surface is configured to its output, acked, and committed with a
// buffer (mapped); the gate then reports the locked frame (locked); unlock_and_-
// destroy disarms the gate.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private final class GateStub: SessionLockDelegate {
    var began = false
    var ended = false
    var mappedSurface: UInt32?
    func sessionLockBegin() -> Bool { began = true; return true }
    func sessionLockEnd() { ended = true }
    func sessionLockSurfaceMapped(_ surface: WlSurface, output: WlOutput?) {
        mappedSurface = surface.objectId
    }
}

@main
enum WaylandSessionLockFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let gate = GateStub()
        let compositor = WlCompositor(); compositor.register(in: router)
        let output = WlOutput(info: OutputInfo(
            physicalWidthMm: 600, physicalHeightMm: 340, pixelWidth: 64, pixelHeight: 48,
            refreshMhz: 60000, scale: 1, name: "LOCK-1", description: "Lock Output"))
        output.register(in: router)
        let lockMgr = SessionLockManager(); lockMgr.delegate = gate; lockMgr.register(in: router)

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

        let compId: UInt32 = 3, shmId: UInt32 = 4, outId: UInt32 = 5, mgrId: UInt32 = 6
        let lock1: UInt32 = 7, lock2: UInt32 = 8, surfId: UInt32 = 9, lockSurf: UInt32 = 10
        let poolId: UInt32 = 11, bufId: UInt32 = 12

        // Grant the first lock; deny the second with finished.
        var a = WireBuilder()
        bind(&a, "wl_compositor", compId)
        bind(&a, "wl_shm", shmId)
        bind(&a, "wl_output", outId)
        bind(&a, "ext_session_lock_manager_v1", mgrId)
        a.message(object: mgrId, opcode: 1) { $0.newId(lock1) }  // lock
        a.message(object: mgrId, opcode: 1) { $0.newId(lock2) }  // lock (denied)
        guard client.send(a) else { fail("send a") }
        client.pump()
        let rA = client.drainEvents()
        guard gate.began else { fail("gate not begun") }
        guard WireMessage.first(rA, object: lock2, opcode: 1) != nil else { fail("no finished on lock2") }
        guard WireMessage.first(rA, object: lock1, opcode: 0) == nil else { fail("premature locked") }

        // Create a lock surface; it is configured to the output (64x48).
        var b = WireBuilder()
        b.message(object: compId, opcode: 0) { $0.newId(surfId) }  // create_surface
        b.message(object: lock1, opcode: 1) {                       // get_lock_surface(id, surface, output)
            $0.newId(lockSurf); $0.object(surfId); $0.object(outId)
        }
        guard client.send(b) else { fail("send b") }
        client.pump()
        let rB = client.drainEvents()
        guard let cfg = WireMessage.first(rB, object: lockSurf, opcode: 0),
            cfg.u32(4) == 64, cfg.u32(8) == 48 else { fail("configure dims") }
        let serial = cfg.u32(0)

        // Allocate a buffer (libwayland shm).
        let poolFd = memfd_create("nucleus-lock-shm", 0)
        guard poolFd >= 0, ftruncate(poolFd, 12288) == 0 else { fail("memfd") }
        var c = WireBuilder()
        c.message(object: shmId, opcode: 0) { $0.newId(poolId); $0.int(12288) }  // create_pool
        c.message(object: poolId, opcode: 0) {                                    // create_buffer
            $0.newId(bufId); $0.int(0); $0.int(64); $0.int(48); $0.int(256); $0.uint(1)
        }
        guard client.send(c, fd: poolFd) else { fail("send c") }
        close(poolFd)
        client.pump()
        _ = client.drainEvents()

        // ack_configure + attach + commit → the lock surface maps.
        var d = WireBuilder()
        d.message(object: lockSurf, opcode: 1) { $0.uint(serial) }                    // ack_configure
        d.message(object: surfId, opcode: 1) { $0.object(bufId); $0.int(0); $0.int(0) }  // attach
        d.message(object: surfId, opcode: 6) { _ in }                                  // commit
        guard client.send(d) else { fail("send d") }
        client.pump()
        _ = client.drainEvents()
        guard gate.mappedSurface == surfId else { fail("lock surface not mapped") }

        // The gate reports the locked frame; the lock emits locked.
        lockMgr.currentLock?.emitLocked()
        let rLocked = client.drainEvents()
        guard WireMessage.first(rLocked, object: lock1, opcode: 0) != nil else { fail("no locked") }

        // Unlock disarms the gate.
        var e = WireBuilder()
        e.message(object: lock1, opcode: 2) { _ in }  // unlock_and_destroy
        guard client.send(e) else { fail("send e") }
        client.pump()
        _ = client.drainEvents()
        guard gate.ended else { fail("gate not ended") }

        print("OK wayland session-lock denied_finished=1 configure=64x48 mapped=1 locked=1 unlocked=1")
    }
}
