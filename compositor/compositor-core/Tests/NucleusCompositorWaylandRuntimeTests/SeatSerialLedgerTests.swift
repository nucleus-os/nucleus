import Testing
@testable import NucleusCompositorWaylandRuntime

@Suite struct SeatSerialLedgerTests {
    @Test func authorizationIsScopedToKindClientSurfaceAndConsumption() {
        let ledger = SeatSerialLedger()
        ledger.record(
            serial: 41,
            kind: .pointerButton,
            clientKey: 7,
            surfaceID: 19)

        #expect(!ledger.authorizes(
            serial: 41, kinds: [.touchDown], clientKey: 7,
            surfaceID: 19, consume: false))
        #expect(!ledger.authorizes(
            serial: 41, kinds: [.pointerButton], clientKey: 8,
            surfaceID: 19, consume: false))
        #expect(!ledger.authorizes(
            serial: 41, kinds: [.pointerButton], clientKey: 7,
            surfaceID: 20, consume: false))
        #expect(ledger.authorizes(
            serial: 41, kinds: [.pointerButton], clientKey: 7,
            surfaceID: 19, consume: true))
        #expect(!ledger.authorizes(
            serial: 41, kinds: [.pointerButton], clientKey: 7,
            surfaceID: 19, consume: false))
    }

    @Test func sessionAndFocusInvalidationRejectStaleAuthority() {
        let ledger = SeatSerialLedger()
        ledger.record(
            serial: 1, kind: .pointerButton,
            clientKey: 10, surfaceID: 100)
        ledger.record(
            serial: 2, kind: .touchDown,
            clientKey: 20, surfaceID: 200)

        ledger.invalidate(kind: .pointerButton, clientKey: 10)
        #expect(!ledger.authorizes(
            serial: 1, kinds: [.pointerButton], clientKey: 10,
            surfaceID: 100, consume: false))
        #expect(ledger.authorizes(
            serial: 2, kinds: [.touchDown], clientKey: 20,
            surfaceID: 200, consume: false))

        ledger.beginNewSession()
        #expect(!ledger.authorizes(
            serial: 2, kinds: [.touchDown], clientKey: 20,
            surfaceID: 200, consume: false))
    }

    @Test func boundedLedgerEvictsOldestAuthority() {
        let ledger = SeatSerialLedger(capacity: 2)
        for serial in UInt32(1)...3 {
            ledger.record(
                serial: serial, kind: .keyboardKey,
                clientKey: 1, surfaceID: 1)
        }

        #expect(!ledger.authorizes(
            serial: 1, kinds: [.keyboardKey], clientKey: 1,
            surfaceID: 1, consume: false))
        #expect(ledger.authorizes(
            serial: 2, kinds: [.keyboardKey], clientKey: 1,
            surfaceID: 1, consume: false))
        #expect(ledger.authorizes(
            serial: 3, kinds: [.keyboardKey], clientKey: 1,
            surfaceID: 1, consume: false))
    }
}
