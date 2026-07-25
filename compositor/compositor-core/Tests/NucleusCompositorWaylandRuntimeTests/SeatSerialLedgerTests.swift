import Testing
import WaylandServer
@testable import NucleusCompositorWaylandRuntime

private func clientID(_ value: UInt) -> WaylandClientID {
    unsafe WaylandClientID(OpaquePointer(bitPattern: value))!
}

@Suite struct SeatSerialLedgerTests {
    @Test func authorizationIsScopedToKindClientSurfaceAndConsumption() {
        let ledger = SeatSerialLedger()
        let client7 = clientID(7)
        let client8 = clientID(8)
        ledger.record(
            serial: 41,
            kind: .pointerButton,
            clientKey: client7,
            surfaceID: 19)

        #expect(!ledger.authorizes(
            serial: 41, kinds: [.touchDown], clientKey: client7,
            surfaceID: 19, consume: false))
        #expect(!ledger.authorizes(
            serial: 41, kinds: [.pointerButton], clientKey: client8,
            surfaceID: 19, consume: false))
        #expect(!ledger.authorizes(
            serial: 41, kinds: [.pointerButton], clientKey: client7,
            surfaceID: 20, consume: false))
        #expect(ledger.authorizes(
            serial: 41, kinds: [.pointerButton], clientKey: client7,
            surfaceID: 19, consume: true))
        #expect(!ledger.authorizes(
            serial: 41, kinds: [.pointerButton], clientKey: client7,
            surfaceID: 19, consume: false))
    }

    @Test func sessionAndFocusInvalidationRejectStaleAuthority() {
        let ledger = SeatSerialLedger()
        let client10 = clientID(10)
        let client20 = clientID(20)
        ledger.record(
            serial: 1, kind: .pointerButton,
            clientKey: client10, surfaceID: 100)
        ledger.record(
            serial: 2, kind: .touchDown,
            clientKey: client20, surfaceID: 200)

        ledger.invalidate(kind: .pointerButton, clientKey: client10)
        #expect(!ledger.authorizes(
            serial: 1, kinds: [.pointerButton], clientKey: client10,
            surfaceID: 100, consume: false))
        #expect(ledger.authorizes(
            serial: 2, kinds: [.touchDown], clientKey: client20,
            surfaceID: 200, consume: false))

        ledger.beginNewSession()
        #expect(!ledger.authorizes(
            serial: 2, kinds: [.touchDown], clientKey: client20,
            surfaceID: 200, consume: false))
    }

    @Test func boundedLedgerEvictsOldestAuthority() {
        let ledger = SeatSerialLedger(capacity: 2)
        let client1 = clientID(1)
        for serial in UInt32(1)...3 {
            ledger.record(
                serial: serial, kind: .keyboardKey,
                clientKey: client1, surfaceID: 1)
        }

        #expect(!ledger.authorizes(
            serial: 1, kinds: [.keyboardKey], clientKey: client1,
            surfaceID: 1, consume: false))
        #expect(ledger.authorizes(
            serial: 2, kinds: [.keyboardKey], clientKey: client1,
            surfaceID: 1, consume: false))
        #expect(ledger.authorizes(
            serial: 3, kinds: [.keyboardKey], clientKey: client1,
            surfaceID: 1, consume: false))
    }
}
