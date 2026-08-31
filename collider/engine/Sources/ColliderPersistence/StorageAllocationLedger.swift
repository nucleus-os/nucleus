import ColliderCore
import Foundation
import SystemPackage

/// What each declared root was measured to hold, the last time anything
/// measured it.
///
/// Allocation used to be answered by walking the store, which is why it sat
/// behind a flag and why the ordinary report had no total: measuring 1.4 TiB to
/// print a number is a cost the question does not justify. A walk is also the
/// wrong shape for the question. Most roots do not change in a given run, so
/// most of that work re-derives what the previous walk already established.
///
/// The record is written by whatever changed a root -- a run that produced into
/// it, a prune that collected from it, a measurement asked for explicitly --
/// and the report reads it. The walk remains, as the way to check the record
/// rather than as the way to answer the question.
public struct StorageAllocationLedger: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let allocatedBytes: UInt64
        public let recordedAt: Date

        public init(allocatedBytes: UInt64, recordedAt: Date) {
            self.allocatedBytes = allocatedBytes
            self.recordedAt = recordedAt
        }
    }

    private let file: FilePath

    public init(root: FilePath) {
        file = root.appending("storage-allocation.json")
    }

    public func load() -> [String: Entry] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: file.string)),
            let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries
    }

    /// Merges measurements into the record.
    ///
    /// Merged rather than replaced, because a caller measures the roots it
    /// touched rather than all of them. A prune that collected from three roots
    /// knows three numbers, and rewriting the file with only those would erase
    /// what every other root last reported and send the next status back to
    /// walking the store.
    ///
    /// A failure to write is not a failure of the operation that measured. The
    /// record is an accelerator for a report, and losing it costs a walk.
    @discardableResult
    public func record(
        _ measurements: [String: UInt64],
        at instant: Date = Date()
    ) -> Bool {
        guard !measurements.isEmpty else { return true }
        var entries = load()
        for (id, bytes) in measurements {
            entries[id] = Entry(allocatedBytes: bytes, recordedAt: instant)
        }
        return (try? DurableFile.writeJSON(entries, to: file)) != nil
    }

    /// Drops roots the catalog no longer declares, so a removed declaration
    /// does not keep reporting bytes nothing owns.
    @discardableResult
    public func retaining(_ declared: Set<String>) -> Bool {
        let entries = load()
        let kept = entries.filter { declared.contains($0.key) }
        guard kept.count != entries.count else { return true }
        return (try? DurableFile.writeJSON(kept, to: file)) != nil
    }
}
