enum XdgConfigureLedgerError: Error, Equatable {
    case invalidSerial
}

/// Ordered configure/ack/commit state for one xdg_surface.
final class XdgConfigureLedger {
    private(set) var outstanding: [XdgConfigureRecord] = []
    private(set) var acknowledged: XdgConfigureRecord?
    private(set) var lastConsumed: XdgConfigureRecord?

    func append(_ record: XdgConfigureRecord) {
        outstanding.append(record)
    }

    func contains(serial: UInt32) -> Bool {
        outstanding.contains { $0.serial == serial }
            || acknowledged?.serial == serial
            || lastConsumed?.serial == serial
    }

    func acknowledge(serial: UInt32) throws(XdgConfigureLedgerError) {
        guard let index = outstanding.firstIndex(where: {
            $0.serial == serial
        }) else {
            throw .invalidSerial
        }
        acknowledged = outstanding[index]
        outstanding.removeFirst(index + 1)
    }

    @discardableResult
    func consumeAcknowledged() -> XdgConfigureRecord? {
        guard let acknowledged else { return nil }
        self.acknowledged = nil
        lastConsumed = acknowledged
        return acknowledged
    }

    func resetForUnmap() {
        outstanding.removeAll(keepingCapacity: true)
        acknowledged = nil
        lastConsumed = nil
    }
}
