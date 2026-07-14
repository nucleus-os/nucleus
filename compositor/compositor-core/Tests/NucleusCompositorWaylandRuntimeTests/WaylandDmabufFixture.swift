// Parity fixture for zwp_linux_dmabuf_v1 on the router:
//   - a v3 bind advertises the supported formats as modifier events;
//   - a v5 bind + get_default_feedback emits the feedback sequence (format_table,
//     main_device, …, done);
//   - create_params + add + create_immed imports a dmabuf into a wl_buffer;
//   - an unsupported format raises the invalid_format protocol error (sent last).

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private let DRM_FORMAT_XRGB8888: UInt32 = 0x3432_5258  // 'XR24'
private let DRM_FORMAT_ARGB8888: UInt32 = 0x3432_5241  // 'AR24'

private final class DmabufStub: DmabufDelegate {
    var importedWidth: Int32?
    var importedFormat: UInt32?
    func dmabufSupportedFormats() -> [DmabufFormat] {
        [DmabufFormat(format: DRM_FORMAT_XRGB8888, modifier: 0),
         DmabufFormat(format: DRM_FORMAT_ARGB8888, modifier: 0)]
    }
    func dmabufMainDevice() -> UInt64 { 0x1234 }
    func dmabufImport(_ attrs: DmabufAttrs) -> Bool {
        importedWidth = attrs.width
        importedFormat = attrs.format
        return true
    }
}

@main
enum WaylandDmabufFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let stub = DmabufStub()
        let dmabuf = ZwpLinuxDmabuf(); dmabuf.delegate = stub; dmabuf.register(in: router)

        guard let client = WaylandTestClient(display: router.display) else { fail("client") }
        let globals = client.globals()
        guard let g = globals.first(where: { $0.interface == "zwp_linux_dmabuf_v1" }) else {
            fail("no zwp_linux_dmabuf_v1")
        }
        func bindAt(_ b: inout WireBuilder, version: UInt32, id: UInt32) {
            b.message(object: 2, opcode: 0) {
                $0.uint(g.name); $0.string("zwp_linux_dmabuf_v1"); $0.uint(version); $0.newId(id)
            }
        }

        let dmaV3: UInt32 = 3, dmaV5: UInt32 = 4, feedbackId: UInt32 = 5
        let params1: UInt32 = 6, bufferId: UInt32 = 7, params2: UInt32 = 8

        // v3 bind: formats advertised as modifier events.
        var a = WireBuilder()
        bindAt(&a, version: 3, id: dmaV3)
        guard client.send(a) else { fail("send a") }
        client.pump()
        let rA = client.drainEvents()
        let modifiers = rA.filter { $0.objectId == dmaV3 && $0.opcode == 1 }
        guard modifiers.count == 2, modifiers[0].u32(0) == DRM_FORMAT_XRGB8888 else {
            fail("modifier events=\(modifiers.count)")
        }

        // v5 bind + default feedback: emits the feedback sequence.
        var b = WireBuilder()
        bindAt(&b, version: 5, id: dmaV5)
        b.message(object: dmaV5, opcode: 2) { $0.newId(feedbackId) }  // get_default_feedback
        guard client.send(b) else { fail("send b") }
        client.pump()
        let rB = client.drainEvents()
        guard let ft = WireMessage.first(rB, object: feedbackId, opcode: 1), ft.u32(0) > 0 else {
            fail("format_table missing/empty")
        }
        guard WireMessage.first(rB, object: feedbackId, opcode: 2) != nil else { fail("main_device") }
        guard WireMessage.first(rB, object: feedbackId, opcode: 0) != nil else { fail("feedback done") }

        // create_params + add + create_immed: a 4x4 XRGB8888 single-plane dmabuf.
        let fd1 = memfd_create("nucleus-dmabuf-plane", 0)
        guard fd1 >= 0 else { fail("memfd") }
        var c = WireBuilder()
        c.message(object: dmaV5, opcode: 1) { $0.newId(params1) }  // create_params
        c.message(object: params1, opcode: 1) {                    // add(fd, plane, off, stride, mod_hi, mod_lo)
            $0.uint(0); $0.uint(0); $0.uint(64); $0.uint(0); $0.uint(0)
        }
        c.message(object: params1, opcode: 3) {                    // create_immed(buffer, w, h, format, flags)
            $0.newId(bufferId); $0.int(4); $0.int(4); $0.uint(DRM_FORMAT_XRGB8888); $0.uint(0)
        }
        guard client.send(c, fd: fd1) else { fail("send c") }
        close(fd1)
        client.pump()
        let rC = client.drainEvents()
        guard WireMessage.first(rC, object: params1, opcode: 1) == nil else { fail("unexpected failed") }
        guard stub.importedWidth == 4, stub.importedFormat == DRM_FORMAT_XRGB8888 else {
            fail("not imported: \(String(describing: stub.importedWidth))")
        }

        // Unsupported format → invalid_format protocol error (sent last; disconnects).
        let fd2 = memfd_create("nucleus-dmabuf-bad", 0)
        guard fd2 >= 0 else { fail("memfd2") }
        var d = WireBuilder()
        d.message(object: dmaV5, opcode: 1) { $0.newId(params2) }  // create_params
        d.message(object: params2, opcode: 1) { $0.uint(0); $0.uint(0); $0.uint(64); $0.uint(0); $0.uint(0) }  // add
        d.message(object: params2, opcode: 2) {                    // create(w, h, format, flags)
            $0.int(4); $0.int(4); $0.uint(0xDEAD_BEEF); $0.uint(0)
        }
        guard client.send(d, fd: fd2) else { fail("send d") }
        close(fd2)
        client.pump()
        let rD = client.drainEvents()
        guard let err = WireMessage.first(rD, object: 1, opcode: 0),
            err.u32(0) == params2, err.u32(4) == 4 else { fail("missing invalid_format error") }

        print("OK wayland dmabuf modifiers=2 feedback_done=1 imported=4x4 invalid_format=1")
    }
}
