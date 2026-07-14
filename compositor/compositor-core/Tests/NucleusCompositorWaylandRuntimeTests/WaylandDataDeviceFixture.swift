// Parity fixture for wl_data_device_manager (clipboard) on the router: a client
// creates a data source advertising two mime types, sets it as the selection, and
// the focused device receives data_offer + offer(mime)* + selection(offer). The
// client then receives(mime, fd) on the offer and the source gets the matching
// send(mime, fd) — the data pipe relay (single client plays both ends).

import Glibc
import WaylandServerC

private func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

@main
enum WaylandDataDeviceFixture {
    static func main() {
        guard let router = NucleusWaylandRouter() else { fail("router") }
        let seat = WlSeat(); seat.register(in: router)
        let dataMgr = WlDataDeviceManager(); dataMgr.register(in: router)

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

        let mgrId: UInt32 = 3, seatId: UInt32 = 4, srcId: UInt32 = 5, devId: UInt32 = 6

        var a = WireBuilder()
        bind(&a, "wl_data_device_manager", mgrId)
        bind(&a, "wl_seat", seatId)
        a.message(object: mgrId, opcode: 0) { $0.newId(srcId) }                     // create_data_source
        a.message(object: srcId, opcode: 0) { $0.string("text/plain") }             // source.offer
        a.message(object: srcId, opcode: 0) { $0.string("text/html") }              // source.offer
        a.message(object: mgrId, opcode: 1) { $0.newId(devId); $0.object(seatId) }  // get_data_device
        a.message(object: devId, opcode: 1) { $0.object(srcId); $0.uint(1) }        // set_selection
        guard client.send(a) else { fail("send a") }
        client.pump()
        let rA = client.drainEvents()

        // The device receives a data_offer; the offer advertises both mimes; the
        // selection event references that offer.
        guard let dataOffer = WireMessage.first(rA, object: devId, opcode: 0) else {
            fail("no data_offer event")
        }
        let offerId = dataOffer.u32(0)
        let mimeCount = rA.filter { $0.objectId == offerId && $0.opcode == 0 }.count
        guard mimeCount == 2 else { fail("offer mimes=\(mimeCount)") }
        let selections = rA.filter { $0.objectId == devId && $0.opcode == 5 }
        guard let sel = selections.last, sel.u32(0) == offerId else { fail("selection mismatch") }

        // receive(mime, fd) on the offer → the source gets send(mime, fd).
        let pipeFd = memfd_create("nucleus-data-pipe", 0)
        guard pipeFd >= 0 else { fail("memfd") }
        var b = WireBuilder()
        b.message(object: offerId, opcode: 1) { $0.string("text/plain") }  // receive(mime, fd)
        guard client.send(b, fd: pipeFd) else { fail("send b") }
        close(pipeFd)
        client.pump()
        let rB = client.drainEvents()
        guard let send = WireMessage.first(rB, object: srcId, opcode: 1),
            let mime = send.string(0), mime == "text/plain" else { fail("source send mime") }

        print("OK wayland data-device offer_mimes=\(mimeCount) selection=1 send_mime=\(mime)")
    }
}
