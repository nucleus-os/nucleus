// Parity fixture for zwlr_gamma_control_manager_v1 on the router: get_gamma_control
// advertises the ramp size; set_gamma reads the client fd's R/G/B ramps and applies
// them; a second control for the same output preempts the first (which receives
// failed).

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

private final class GammaStub: GammaControlDelegate {
    var appliedSize: Int?
    var red0: UInt16?
    var red255: UInt16?
    func gammaRampSize(output: WlOutput?) -> UInt32 { 256 }
    func gammaApply(output: WlOutput?, red: [UInt16], green: [UInt16], blue: [UInt16]) {
        appliedSize = red.count
        red0 = red.first
        red255 = red.last
    }
}

@main
enum WaylandGammaFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let stub = GammaStub()
        let output = WlOutput(info: OutputInfo(
            physicalWidthMm: 600, physicalHeightMm: 340, pixelWidth: 2560, pixelHeight: 1440,
            refreshMhz: 60000, scale: 1, name: "GAMMA-1", description: "Gamma Output"))
        output.register(in: router)
        let gamma = ZwlrGammaControlManager(); gamma.delegate = stub; gamma.register(in: router)

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

        let mgrId: UInt32 = 3, outId: UInt32 = 4, ctrl1: UInt32 = 5, ctrl2: UInt32 = 6

        // get_gamma_control advertises the ramp size.
        var a = WireBuilder()
        bind(&a, "zwlr_gamma_control_manager_v1", mgrId)
        bind(&a, "wl_output", outId)
        a.message(object: mgrId, opcode: 0) { $0.newId(ctrl1); $0.object(outId) }  // get_gamma_control
        guard client.send(a) else { fail("send a") }
        client.pump()
        let rA = client.drainEvents()
        guard let gs = WireMessage.first(rA, object: ctrl1, opcode: 0), gs.u32(0) == 256 else {
            fail("gamma_size != 256")
        }

        // set_gamma: 3 * 256 host-endian uint16 ramps (red[i] = i * 257 → 0..65535).
        let size = 256
        var ramp = [UInt8]()
        ramp.reserveCapacity(size * 3 * 2)
        for _ in 0..<3 {
            for i in 0..<size {
                let v = UInt16(i * 257)
                ramp.append(UInt8(v & 0xff)); ramp.append(UInt8(v >> 8))
            }
        }
        let rampFd = memfd_create("nucleus-gamma-ramp", 0)
        guard rampFd >= 0 else { fail("memfd") }
        _ = ramp.withUnsafeBytes { write(rampFd, $0.baseAddress, $0.count) }
        var b = WireBuilder()
        b.message(object: ctrl1, opcode: 0) { _ in }  // set_gamma(fd)
        guard client.send(b, fd: rampFd) else { fail("send b") }
        close(rampFd)
        client.pump()
        _ = client.drainEvents()
        guard stub.appliedSize == 256, stub.red0 == 0, stub.red255 == 65535 else {
            fail("gamma not applied: size=\(String(describing: stub.appliedSize)) "
                + "red0=\(String(describing: stub.red0)) red255=\(String(describing: stub.red255))")
        }

        // A second control preempts the first, which receives failed.
        var c = WireBuilder()
        c.message(object: mgrId, opcode: 0) { $0.newId(ctrl2); $0.object(outId) }  // get_gamma_control
        guard client.send(c) else { fail("send c") }
        client.pump()
        let rC = client.drainEvents()
        guard WireMessage.first(rC, object: ctrl1, opcode: 1) != nil else { fail("no preempt failed") }

        print("OK wayland gamma size=256 applied_size=256 red0=0 red255=65535 preempt_failed=1")
    }
}
