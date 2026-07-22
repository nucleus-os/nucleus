//
// Window damage/animation footprint tracking keyed by output id. FIFO eviction
// when the table fills: drops the oldest entry (index 0) and appends the new
// one, so the newest entry is always findable by `get`. Generic over the output
// id and the stored rect; nothing imports it yet.

let maxTrackedPresentedOutputs: Int = 16

/// Fixed-capacity insertion-ordered map of output id → rect with FIFO overflow.
struct PerOutputRenderRects<OutputId: Equatable, Rect> {
    private struct Entry {
        var outputId: OutputId
        var rect: Rect
    }

    private var entries: [Entry] = []

    init() {
        entries.reserveCapacity(maxTrackedPresentedOutputs)
    }

    var count: Int { entries.count }

    func get(_ outputId: OutputId) -> Rect? {
        for entry in entries where entry.outputId == outputId {
            return entry.rect
        }
        return nil
    }

    /// Insert or update the rect for `outputId`. When the fixed table is full,
    /// the oldest entry (index 0) is evicted FIFO and the new entry appended;
    /// the new entry is therefore always findable by `get`.
    mutating func put(_ outputId: OutputId, _ rect: Rect) {
        for i in entries.indices where entries[i].outputId == outputId {
            entries[i].rect = rect
            return
        }
        if entries.count < maxTrackedPresentedOutputs {
            entries.append(Entry(outputId: outputId, rect: rect))
            return
        }
        entries.removeFirst()
        entries.append(Entry(outputId: outputId, rect: rect))
    }

    /// Remove the entry for `outputId` if present (swap-remove,
    /// order-not-preserved removal).
    mutating func remove(_ outputId: OutputId) {
        for i in entries.indices where entries[i].outputId == outputId {
            entries[i] = entries[entries.count - 1]
            entries.removeLast()
            return
        }
    }
}
