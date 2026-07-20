import Testing
@testable import NucleusCompositorWaylandRuntime

@Suite struct XdgConfigureLedgerTests {
    private static func record(_ serial: UInt32) -> XdgConfigureRecord {
        XdgConfigureRecord(
            serial: serial,
            roleState: .toplevel(XdgToplevelConfigure(
                width: Int32(serial), height: 600, states: [])),
            initial: serial == 1)
    }

    @Test func acknowledgingNewestConsumesOlderOutstandingRecords() throws {
        let ledger = XdgConfigureLedger()
        ledger.append(Self.record(1))
        ledger.append(Self.record(2))
        ledger.append(Self.record(3))

        try ledger.acknowledge(serial: 2)
        #expect(ledger.acknowledged?.serial == 2)
        #expect(ledger.outstanding.map(\.serial) == [3])
        #expect(ledger.consumeAcknowledged()?.serial == 2)
        #expect(ledger.lastConsumed?.serial == 2)
    }

    @Test func duplicateUnknownAndStaleAcknowledgementsFail() throws {
        let ledger = XdgConfigureLedger()
        ledger.append(Self.record(10))
        try ledger.acknowledge(serial: 10)

        #expect(throws: XdgConfigureLedgerError.invalidSerial) {
            try ledger.acknowledge(serial: 10)
        }
        #expect(throws: XdgConfigureLedgerError.invalidSerial) {
            try ledger.acknowledge(serial: 9)
        }
        _ = ledger.consumeAcknowledged()
        #expect(throws: XdgConfigureLedgerError.invalidSerial) {
            try ledger.acknowledge(serial: 10)
        }
    }

    @Test func laterUnackedConfigureDoesNotReplaceCommittedAck() throws {
        let ledger = XdgConfigureLedger()
        ledger.append(Self.record(20))
        try ledger.acknowledge(serial: 20)
        ledger.append(Self.record(21))

        #expect(ledger.consumeAcknowledged()?.serial == 20)
        #expect(ledger.outstanding.map(\.serial) == [21])
    }

    @Test func unmapResetsEveryConfigureEpoch() throws {
        let ledger = XdgConfigureLedger()
        ledger.append(Self.record(30))
        try ledger.acknowledge(serial: 30)
        _ = ledger.consumeAcknowledged()
        ledger.append(Self.record(31))
        ledger.resetForUnmap()

        #expect(ledger.outstanding.isEmpty)
        #expect(ledger.acknowledged == nil)
        #expect(ledger.lastConsumed == nil)
        #expect(!ledger.contains(serial: 30))
        #expect(!ledger.contains(serial: 31))
    }
}
