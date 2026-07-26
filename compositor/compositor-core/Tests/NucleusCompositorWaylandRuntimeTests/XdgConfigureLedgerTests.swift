import Testing
@testable import NucleusCompositorWaylandRuntime

@MainActor
@Suite struct XdgConfigureLedgerTests {
    private static func record(_ serial: UInt32) -> XdgConfigureRecord {
        XdgConfigureRecord(
            serial: configureSerial(serial),
            roleState: .toplevel(XdgToplevelConfigure(
                width: Int32(serial), height: 600, states: [])),
            initial: serial == 1)
    }

    private static func configureSerial(
        _ rawValue: UInt32
    ) -> XdgConfigureSerial {
        XdgConfigureSerial(rawValue: rawValue)
    }

    @Test func acknowledgingNewestConsumesOlderOutstandingRecords() throws {
        let ledger = XdgConfigureLedger()
        ledger.append(Self.record(1))
        ledger.append(Self.record(2))
        ledger.append(Self.record(3))

        try ledger.acknowledge(serial: Self.configureSerial(2))
        #expect(ledger.acknowledged?.serial.rawValue == 2)
        #expect(ledger.outstanding.map(\.serial.rawValue) == [3])
        #expect(ledger.consumeAcknowledged()?.serial.rawValue == 2)
        #expect(ledger.lastConsumed?.serial.rawValue == 2)
    }

    @Test func duplicateUnknownAndStaleAcknowledgementsFail() throws {
        let ledger = XdgConfigureLedger()
        ledger.append(Self.record(10))
        try ledger.acknowledge(serial: Self.configureSerial(10))

        #expect(throws: XdgConfigureLedgerError.invalidSerial) {
            try ledger.acknowledge(serial: Self.configureSerial(10))
        }
        #expect(throws: XdgConfigureLedgerError.invalidSerial) {
            try ledger.acknowledge(serial: Self.configureSerial(9))
        }
        _ = ledger.consumeAcknowledged()
        #expect(throws: XdgConfigureLedgerError.invalidSerial) {
            try ledger.acknowledge(serial: Self.configureSerial(10))
        }
    }

    @Test func laterUnackedConfigureDoesNotReplaceCommittedAck() throws {
        let ledger = XdgConfigureLedger()
        ledger.append(Self.record(20))
        try ledger.acknowledge(serial: Self.configureSerial(20))
        ledger.append(Self.record(21))

        #expect(ledger.consumeAcknowledged()?.serial.rawValue == 20)
        #expect(ledger.outstanding.map(\.serial.rawValue) == [21])
    }

    @Test func unmapResetsEveryConfigureEpoch() throws {
        let ledger = XdgConfigureLedger()
        ledger.append(Self.record(30))
        try ledger.acknowledge(serial: Self.configureSerial(30))
        _ = ledger.consumeAcknowledged()
        ledger.append(Self.record(31))
        ledger.resetForUnmap()

        #expect(ledger.outstanding.isEmpty)
        #expect(ledger.acknowledged == nil)
        #expect(ledger.lastConsumed == nil)
        #expect(!ledger.contains(serial: Self.configureSerial(30)))
        #expect(!ledger.contains(serial: Self.configureSerial(31)))
    }
}
