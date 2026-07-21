/// A bounded least-recently-used cache for collection measurements.
///
/// List and grid intentionally share only this value-level mechanism. Snapshot
/// ownership, layout invalidation, selection, and recycling stay in the
/// collection that understands their geometry.
package struct CollectionMeasurementCache {
    package struct Key: Hashable {
        let itemID: CollectionItemID
        let revision: UInt64
        let width: Double
        let environmentGeneration: UInt64
        let backingScaleBits: UInt32
    }

    private struct Entry {
        var value: Double
        var access: UInt64
    }

    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var nextAccess: UInt64 = 1

    package init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    package var count: Int { entries.count }

    package mutating func value(
        for key: Key,
        measure: () -> Double
    ) -> Double {
        let access = takeAccess()
        if var entry = entries[key] {
            entry.access = access
            entries[key] = entry
            return entry.value
        }

        let proposed = measure()
        let value = proposed.isFinite ? max(0, proposed) : 0
        if entries.count == capacity,
           let oldest = entries.min(by: {
               $0.value.access < $1.value.access
           })?.key
        {
            entries[oldest] = nil
        }
        entries[key] = Entry(value: value, access: access)
        return value
    }

    package mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private mutating func takeAccess() -> UInt64 {
        let access = nextAccess
        nextAccess &+= 1
        if nextAccess == 0 {
            // Capacity is bounded, so renumbering the retained entries is
            // deterministic and prevents an impossible-in-practice wrap from
            // reversing eviction order.
            let ordered = entries.sorted {
                $0.value.access < $1.value.access
            }
            entries.removeAll(keepingCapacity: true)
            for (offset, pair) in ordered.enumerated() {
                entries[pair.key] = Entry(
                    value: pair.value.value,
                    access: UInt64(offset + 1))
            }
            nextAccess = UInt64(entries.count + 1)
        }
        return access
    }
}
