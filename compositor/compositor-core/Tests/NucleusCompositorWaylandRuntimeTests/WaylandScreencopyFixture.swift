// Parity fixture for zwlr_screencopy_manager_v1 on the router: capture_output
// advertises the required buffer (+ linux_dmabuf + buffer_done at v3); a copy into
// a matching (libwayland shm) buffer reports flags + ready; an uncapturable region
// reports failed; a second copy on a used frame raises already_used (sent last).

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private final class ScreencopyStub: ScreencopyDelegate {
    let full = ScreencopyParams(shmFormat: 1, width: 64, height: 48, stride: 256, drmFourcc: 0x3432_5258)
    func screencopyParams(output: WlOutput?, region: WlRect?) -> ScreencopyParams? {
        region == nil ? full : nil  // region capture "unsupported" here → failed
    }
    func screencopyCapture(
        output: WlOutput?, region: WlRect?,
        buffer: UnsafeMutablePointer<wl_resource>, withDamage: Bool) -> ScreencopyResult {
        ScreencopyResult(ok: true, tvSecHi: 0, tvSecLo: 99, tvNsec: 11, flags: 1)
    }
}

@main
enum WaylandScreencopyFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let stub = ScreencopyStub()
        let output = WlOutput(info: OutputInfo(
            physicalWidthMm: 600, physicalHeightMm: 340, pixelWidth: 64, pixelHeight: 48,
            refreshMhz: 60000, scale: 1, name: "CAP-1", description: "Capture Output"))
        output.register(in: router)
        let screencopy = ScreencopyManager(); screencopy.delegate = stub; screencopy.register(in: router)

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

        let shmId: UInt32 = 3, outId: UInt32 = 4, mgrId: UInt32 = 5
        let frame1: UInt32 = 6, poolId: UInt32 = 7, bufId: UInt32 = 8, frame2: UInt32 = 9

        // capture_output advertises the buffer.
        var a = WireBuilder()
        bind(&a, "wl_shm", shmId)
        bind(&a, "wl_output", outId)
        bind(&a, "zwlr_screencopy_manager_v1", mgrId)
        a.message(object: mgrId, opcode: 0) { $0.newId(frame1); $0.int(0); $0.object(outId) }  // capture_output
        guard client.send(a) else { fail("send a") }
        client.pump()
        let rA = client.drainEvents()
        guard let buf = WireMessage.first(rA, object: frame1, opcode: 0),
            buf.u32(0) == 1, buf.u32(4) == 64, buf.u32(8) == 48, buf.u32(12) == 256
        else { fail("buffer event args") }
        guard WireMessage.first(rA, object: frame1, opcode: 5) != nil else { fail("no linux_dmabuf") }
        guard WireMessage.first(rA, object: frame1, opcode: 6) != nil else { fail("no buffer_done") }

        // Allocate a matching shm buffer (64x48, stride 256 → 12288 bytes).
        let poolFd = memfd_create("nucleus-screencopy-shm", 0)
        guard poolFd >= 0, ftruncate(poolFd, 12288) == 0 else { fail("memfd") }
        var b = WireBuilder()
        b.message(object: shmId, opcode: 0) { $0.newId(poolId); $0.int(12288) }  // create_pool
        b.message(object: poolId, opcode: 0) {                                    // create_buffer
            $0.newId(bufId); $0.int(0); $0.int(64); $0.int(48); $0.int(256); $0.uint(1)
        }
        guard client.send(b, fd: poolFd) else { fail("send b") }
        close(poolFd)
        client.pump()
        _ = client.drainEvents()

        // copy → flags + ready.
        var c = WireBuilder()
        c.message(object: frame1, opcode: 0) { $0.object(bufId) }  // copy
        guard client.send(c) else { fail("send c") }
        client.pump()
        let rC = client.drainEvents()
        guard let flags = WireMessage.first(rC, object: frame1, opcode: 1), flags.u32(0) == 1 else {
            fail("flags")
        }
        guard let ready = WireMessage.first(rC, object: frame1, opcode: 2),
            ready.u32(0) == 0, ready.u32(4) == 99, ready.u32(8) == 11 else { fail("ready") }

        // An uncapturable region → failed.
        var d = WireBuilder()
        d.message(object: mgrId, opcode: 1) {  // capture_output_region
            $0.newId(frame2); $0.int(0); $0.object(outId); $0.int(0); $0.int(0); $0.int(32); $0.int(32)
        }
        guard client.send(d) else { fail("send d") }
        client.pump()
        let rD = client.drainEvents()
        guard WireMessage.first(rD, object: frame2, opcode: 3) != nil else { fail("no failed") }

        // Second copy on a used frame → already_used (sent last; disconnects).
        var e = WireBuilder()
        e.message(object: frame1, opcode: 0) { $0.object(bufId) }  // copy again
        guard client.send(e) else { fail("send e") }
        client.pump()
        let rE = client.drainEvents()
        guard let err = WireMessage.first(rE, object: 1, opcode: 0),
            err.u32(0) == frame1, err.u32(4) == 0 else { fail("no already_used error") }

        print("OK wayland screencopy buffer=64x48:256 dmabuf=1 flags=1 ready=99.11 failed=1 already_used=1")
    }
}
