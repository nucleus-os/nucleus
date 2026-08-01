import WaylandServer

/// Provenance for serials minted by one `wl_seat`.
///
/// A serial is useful only inside the session generation and focus lifetime in
/// which the corresponding input event was delivered. Keeping that provenance in
/// one owner prevents XDG grabs and other privileged requests from treating an
/// arbitrary display serial as proof of user intent.
enum SeatSerialKind: Hashable, Sendable {
    case pointerEnter
    case pointerButton
    case touchDown
    case keyboardKey
}

struct SeatSerialRecord: Equatable, Sendable {
    let serial: SeatInputSerial
    let kind: SeatSerialKind
    let clientKey: WaylandClientID
    let surfaceID: UInt32?
    let sessionGeneration: UInt64
}

final class SeatSerialLedger {
    private var sessionGeneration: UInt64 = 1
    private var records: [SeatInputSerial: SeatSerialRecord] = [:]
    private var order: [SeatInputSerial] = []
    private let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    @discardableResult
    func record(
        serial: SeatInputSerial,
        kind: SeatSerialKind,
        clientKey: WaylandClientID,
        surfaceID: UInt32?
    ) -> SeatSerialRecord {
        let record = SeatSerialRecord(
            serial: serial,
            kind: kind,
            clientKey: clientKey,
            surfaceID: surfaceID,
            sessionGeneration: sessionGeneration)
        if records[serial] == nil { order.append(serial) }
        records[serial] = record
        while order.count > capacity {
            records[order.removeFirst()] = nil
        }
        return record
    }

    func authorizes(
        serial: SeatInputSerial,
        kinds: Set<SeatSerialKind>,
        clientKey: WaylandClientID,
        surfaceID: UInt32?,
        consume: Bool
    ) -> Bool {
        guard let record = records[serial],
            record.sessionGeneration == sessionGeneration,
            record.clientKey == clientKey,
            kinds.contains(record.kind),
            surfaceID == nil || record.surfaceID == surfaceID
        else { return false }
        if consume {
            records[serial] = nil
            order.removeAll { $0 == serial }
        }
        return true
    }

    func invalidate(kind: SeatSerialKind, clientKey: WaylandClientID? = nil) {
        let rejected = Set<SeatInputSerial>(
            records.values.compactMap { record -> SeatInputSerial? in
                guard record.kind == kind,
                    clientKey == nil || record.clientKey == clientKey
                else { return nil }
                return record.serial
            })
        guard !rejected.isEmpty else { return }
        for serial in rejected { records[serial] = nil }
        order.removeAll { rejected.contains($0) }
    }

    func invalidate(clientKey: WaylandClientID) {
        let rejected = Set<SeatInputSerial>(
            records.values.compactMap {
                $0.clientKey == clientKey ? $0.serial : nil
            })
        for serial in rejected { records[serial] = nil }
        order.removeAll { rejected.contains($0) }
    }

    func beginNewSession() {
        sessionGeneration &+= 1
        records.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}
