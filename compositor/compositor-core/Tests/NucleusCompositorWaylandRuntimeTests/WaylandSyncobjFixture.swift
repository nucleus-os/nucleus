// Parity fixture for wp_linux_drm_syncobj_manager_v1 on the router: import a
// timeline, create a syncobj surface, attach a (libwayland shm) buffer, set an
// acquire + release point, and commit — the materialized points reach the DRM
// delegate. An acquire point at or past the release point on the same timeline
// raises conflicting_points (sent last; disconnects).

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private final class SyncobjStub: DrmSyncobjDelegate {
    let handle: UInt32 = 0x100
    var acquire: SyncPoint?
    var release: SyncPoint?
    func importSyncobjTimeline(fd: Int32) -> UInt32? { handle }
    func syncobjCommit(_ surface: WlSurface, acquire: SyncPoint, release: SyncPoint) {
        self.acquire = acquire
        self.release = release
    }
}

@main
enum WaylandSyncobjFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let stub = SyncobjStub()
        let compositor = WlCompositor(); compositor.register(in: router)
        let syncobj = WpLinuxDrmSyncobjManager(); syncobj.delegate = stub; syncobj.register(in: router)

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

        let compId: UInt32 = 3, shmId: UInt32 = 4, syncMgr: UInt32 = 5, surfId: UInt32 = 6
        let poolId: UInt32 = 7, bufId: UInt32 = 8, timelineId: UInt32 = 9, syncSurf: UInt32 = 10

        var a = WireBuilder()
        bind(&a, "wl_compositor", compId)
        bind(&a, "wl_shm", shmId)
        bind(&a, "wp_linux_drm_syncobj_manager_v1", syncMgr)
        a.message(object: compId, opcode: 0) { $0.newId(surfId) }  // create_surface
        guard client.send(a) else { fail("send a") }
        client.pump()
        _ = client.drainEvents()

        // An shm pool + one 4x4 XRGB8888 buffer (libwayland owns wl_shm).
        let poolFd = memfd_create("nucleus-syncobj-shm", 0)
        guard poolFd >= 0, ftruncate(poolFd, 256) == 0 else { fail("memfd") }
        var b = WireBuilder()
        b.message(object: shmId, opcode: 0) { $0.newId(poolId); $0.int(256) }  // create_pool(id, fd, size)
        b.message(object: poolId, opcode: 0) {                                  // create_buffer
            $0.newId(bufId); $0.int(0); $0.int(4); $0.int(4); $0.int(16); $0.uint(1)  // XRGB8888
        }
        guard client.send(b, fd: poolFd) else { fail("send b") }
        close(poolFd)
        client.pump()
        _ = client.drainEvents()

        // Import a timeline and create a syncobj surface.
        let timelineFd = memfd_create("nucleus-syncobj-timeline", 0)
        guard timelineFd >= 0 else { fail("memfd timeline") }
        var c = WireBuilder()
        c.message(object: syncMgr, opcode: 2) { $0.newId(timelineId) }              // import_timeline(id, fd)
        c.message(object: syncMgr, opcode: 1) { $0.newId(syncSurf); $0.object(surfId) }  // get_surface
        guard client.send(c, fd: timelineFd) else { fail("send c") }
        close(timelineFd)
        client.pump()
        _ = client.drainEvents()

        // Attach the buffer, set acquire (5) + release (10), commit.
        var d = WireBuilder()
        d.message(object: surfId, opcode: 1) { $0.object(bufId); $0.int(0); $0.int(0) }  // attach
        d.message(object: syncSurf, opcode: 1) { $0.object(timelineId); $0.uint(0); $0.uint(5) }   // set_acquire_point
        d.message(object: syncSurf, opcode: 2) { $0.object(timelineId); $0.uint(0); $0.uint(10) }  // set_release_point
        d.message(object: surfId, opcode: 6) { _ in }  // commit
        guard client.send(d) else { fail("send d") }
        client.pump()
        _ = client.drainEvents()
        guard let acq = stub.acquire, let rel = stub.release,
            acq.handle == stub.handle, acq.point == 5, rel.point == 10 else {
            fail("syncobj commit not delivered: \(String(describing: stub.acquire))")
        }

        // acquire >= release on the same timeline → conflicting_points (last).
        var e = WireBuilder()
        e.message(object: syncSurf, opcode: 1) { $0.object(timelineId); $0.uint(0); $0.uint(10) }
        e.message(object: syncSurf, opcode: 2) { $0.object(timelineId); $0.uint(0); $0.uint(5) }
        e.message(object: surfId, opcode: 6) { _ in }  // commit (buffer still attached)
        guard client.send(e) else { fail("send e") }
        client.pump()
        let rE = client.drainEvents()
        guard let err = WireMessage.first(rE, object: 1, opcode: 0),
            err.u32(0) == syncSurf, err.u32(4) == 6 else { fail("missing conflicting_points error") }

        print("OK wayland syncobj imported_handle=\(stub.handle) acquire=\(acq.point) "
            + "release=\(rel.point) conflicting=1")
    }
}
