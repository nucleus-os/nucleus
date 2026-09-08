import ColliderCore
import Synchronization

/// Collects the identity components planning encoded for selected tasks.
///
/// Planning may run more than once for one command, so the first encoding of a
/// task is the one kept: a later pass differs only in what output validation
/// found, which is not part of the identity being explained.
package final class IdentityExplanationCollector: Sendable {
    private let selection: String?
    private let encoded = Mutex<[TaskID: [PlannedIdentityKind: [UInt8]]]>([:])
    private let divergences = Mutex<[TaskID: (recorded: [UInt8], planned: [UInt8])]>([:])

    package init(selection: String?) {
        self.selection = selection
    }

    package var isEnabled: Bool { selection != nil }

    package var observer: (@Sendable (TaskID, PlannedIdentityKind, [UInt8]) -> Void)? {
        guard let selection else { return nil }
        return { [self] task, kind, bytes in
            guard task.rawValue.contains(selection) else { return }
            encoded.withLock {
                if $0[task, default: [:]][kind] == nil {
                    $0[task, default: [:]][kind] = bytes
                }
            }
        }
    }

    /// Both encodings behind a record planning rejected.
    ///
    /// Carried as a pair rather than paired later with what `observer` saw. A
    /// lowered task is named by one identity and assessed by another, so the
    /// components displayed for it are not the components compared, and
    /// pairing the two here would report a difference between things that
    /// were never the same question.
    package var divergenceObserver: (@Sendable (TaskID, [UInt8], [UInt8]) -> Void)? {
        guard let selection else { return nil }
        return { [self] task, recorded, planned in
            guard task.rawValue.contains(selection) else { return }
            divergences.withLock {
                if $0[task] == nil { $0[task] = (recorded, planned) }
            }
        }
    }

    /// The collected components, rendered one component per line beneath the
    /// task that encoded them.
    package func report() -> [String] {
        let collected = encoded.withLock { $0 }
        guard !collected.isEmpty else {
            guard let selection else { return [] }
            return ["identity  no planned or lowered task contains \"\(selection)\""]
        }
        let diverged = divergences.withLock { $0 }
        var lines: [String] = []
        for task in collected.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            lines.append("identity  \(task.rawValue)")
            let encodings = collected[task] ?? [:]
            // Assessment first, and labelled, because a lowered task has two
            // encodings and only this one answers why it is running. The name
            // follows for the same reason it is captured at all: nothing else
            // can reconstruct it once the lowering that invented it is gone.
            for (label, kind) in [
                ("assessed by", PlannedIdentityKind.assessment),
                ("named from", PlannedIdentityKind.name),
            ] {
                guard let bytes = encodings[kind] else { continue }
                lines.append("  \(label)")
                guard let nodes = IdentityTrace.decode(bytes) else {
                    lines.append("    <identity components are not decodable>")
                    continue
                }
                lines += IdentityTrace.render(nodes, indent: 2)
            }
            lines += divergence(of: task, in: diverged)
        }
        return lines
    }

    /// Where this plan stopped agreeing with the last execution's record.
    ///
    /// Only for a task planning is rerunning because the two disagree. A task
    /// that matches its record has nothing to compare, and one that never ran
    /// has nothing to compare against.
    private func divergence(
        of task: TaskID,
        in diverged: [TaskID: (recorded: [UInt8], planned: [UInt8])]
    ) -> [String] {
        guard let pair = diverged[task] else { return [] }
        guard !pair.recorded.isEmpty else {
            return [
                "  diverged from a recorded identity that kept no components,",
                "  which is every record written before they were kept. This",
                "  task is locatable once it next executes.",
            ]
        }
        guard let recorded = IdentityTrace.decode(pair.recorded),
            let planned = IdentityTrace.decode(pair.planned)
        else {
            return ["  <the compared identity components are not decodable>"]
        }
        let difference = IdentityTrace.difference(
            recorded: recorded, planned: planned)
        guard !difference.isEmpty else {
            // Reachable: the digests differ while the components render
            // alike, which says the difference is in bytes the rendering
            // elides rather than in the shape of the encoding.
            return ["  diverged from the recorded identity in undisplayed bytes"]
        }
        return ["  diverged from the recorded identity at"]
            + difference.map { "  " + $0 }
    }
}
