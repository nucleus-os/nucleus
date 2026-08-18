import OrderedCollections
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
    /// Element order is eviction order: the oldest recorded serial is first.
    /// Re-recording an existing serial refreshes its provenance and keeps its
    /// position, so a client cannot extend a serial's lifetime by replaying it.
    private var records: OrderedDictionary<SeatInputSerial, SeatSerialRecord> = [:]
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
        records[serial] = record
        while records.count > capacity { records.removeFirst() }
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
        if consume { records.removeValue(forKey: serial) }
        return true
    }

    func invalidate(kind: SeatSerialKind, clientKey: WaylandClientID? = nil) {
        records.removeAll { _, record in
            record.kind == kind && (clientKey == nil || record.clientKey == clientKey)
        }
    }

    func invalidate(clientKey: WaylandClientID) {
        records.removeAll { $1.clientKey == clientKey }
    }

    func beginNewSession() {
        sessionGeneration &+= 1
        records.removeAll(keepingCapacity: true)
    }
}
