// Parity fixture for the wl_surface buffer lifecycle end to end: a real wl_shm
// pool (an fd passed via SCM_RIGHTS to libwayland-owned wl_shm) backs two
// wl_buffers; attaching+committing the first takes no release, and committing a
// second buffer releases the first (wl_buffer.release). This exercises the Swift
// surface model's attach/commit/replace-release against libwayland's own SHM.

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

@main
enum WaylandBufferFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let compositor = WlCompositor()
        compositor.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        func name(_ iface: String) -> (name: UInt32, version: UInt32) {
            guard let g = globals.first(where: { $0.interface == iface }) else { fail("no \(iface)") }
            return (g.name, g.version)
        }
        let shm = name("wl_shm")
        let comp = name("wl_compositor")

        // A small SHM pool holding two 4x4 ARGB buffers at offsets 0 and 64.
        let poolSize: Int32 = 256
        let fd = memfd_create("nucleus-shm-fixture", 0)
        guard fd >= 0, ftruncate(fd, off_t(poolSize)) == 0 else { fail("memfd") }

        // ids: shm 3, compositor 4, pool 5, bufA 6, bufB 7, surface 8.
        let shmId: UInt32 = 3, compId: UInt32 = 4, poolId: UInt32 = 5
        let bufA: UInt32 = 6, bufB: UInt32 = 7, surfId: UInt32 = 8

        var b1 = WireBuilder()
        b1.message(object: 2, opcode: 0) {  // bind wl_shm
            $0.uint(shm.name); $0.string("wl_shm"); $0.uint(shm.version); $0.newId(shmId)
        }
        b1.message(object: 2, opcode: 0) {  // bind wl_compositor
            $0.uint(comp.name); $0.string("wl_compositor"); $0.uint(comp.version); $0.newId(compId)
        }
        b1.message(object: shmId, opcode: 0) { $0.newId(poolId); $0.int(poolSize) }  // create_pool (fd ancillary)
        b1.message(object: poolId, opcode: 0) {  // create_buffer bufA: offset,w,h,stride,format(ARGB8888=0)
            $0.newId(bufA); $0.int(0); $0.int(4); $0.int(4); $0.int(16); $0.uint(0)
        }
        b1.message(object: poolId, opcode: 0) {  // create_buffer bufB
            $0.newId(bufB); $0.int(64); $0.int(4); $0.int(4); $0.int(16); $0.uint(0)
        }
        b1.message(object: compId, opcode: 0) { $0.newId(surfId) }  // create_surface
        guard client.send(b1, fd: fd) else { fail("send b1") }
        close(fd)  // libwayland dup'd it into the pool
        client.pump()
        _ = client.drainEvents()  // discard shm formats + preferred scale

        // Attach + commit bufA: it becomes current, nothing is replaced.
        var b2 = WireBuilder()
        b2.message(object: surfId, opcode: 1) { $0.object(bufA); $0.int(0); $0.int(0) }  // attach
        b2.message(object: surfId, opcode: 6) { _ in }  // commit
        guard client.send(b2) else { fail("send b2") }
        client.pump()
        let afterFirst = client.drainEvents()
        let releaseBefore = WireMessage.first(afterFirst, object: bufA, opcode: 0) != nil ? 1 : 0
        guard releaseBefore == 0 else { fail("bufA released before replacement") }

        // Attach + commit bufB: bufA is replaced and must be released.
        var b3 = WireBuilder()
        b3.message(object: surfId, opcode: 1) { $0.object(bufB); $0.int(0); $0.int(0) }  // attach
        b3.message(object: surfId, opcode: 6) { _ in }  // commit
        guard client.send(b3) else { fail("send b3") }
        client.pump()
        let afterSecond = client.drainEvents()
        let releaseAfter = WireMessage.first(afterSecond, object: bufA, opcode: 0) != nil ? 1 : 0
        guard releaseAfter == 1 else { fail("bufA not released after replacement") }

        print("OK wayland buffer release_after_replace=\(releaseAfter) "
            + "release_before_replace=\(releaseBefore)")
    }
}
