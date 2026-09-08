import ColliderCore
import Synchronization

/// Collects the identity components planning encoded for selected tasks.
///
/// Planning may run more than once for one command, so the first encoding of a
/// task is the one kept: a later pass differs only in what output validation
/// found, which is not part of the identity being explained.
package final class IdentityExplanationCollector: Sendable {
    private let selection: String?
    private let encoded = Mutex<[TaskID: [UInt8]]>([:])
    private let divergences = Mutex<[TaskID: (recorded: [UInt8], planned: [UInt8])]>([:])

    package init(selection: String?) {
        self.selection = selection
    }

    package var isEnabled: Bool { selection != nil }

    package var observer: (@Sendable (TaskID, [UInt8]) -> Void)? {
        guard let selection else { return nil }
        return { [self] task, bytes in
            guard task.rawValue.contains(selection) else { return }
            encoded.withLock { if $0[task] == nil { $0[task] = bytes } }
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
            guard let nodes = IdentityTrace.decode(collected[task] ?? []) else {
                lines.append("  <identity components are not decodable>")
                continue
            }
            lines += IdentityTrace.render(nodes, indent: 1)
            lines += divergence(
                of: task, displaying: collected[task] ?? [], in: diverged)
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
        displaying displayed: [UInt8],
        in diverged: [TaskID: (recorded: [UInt8], planned: [UInt8])]
    ) -> [String] {
        guard let pair = diverged[task] else { return [] }
        // A lowering names its task from one encoding and planning assesses it
        // by another, so for those the components above are not the components
        // compared. Saying so beats leaving a reader to match a reported
        // difference against lines that do not contain it.
        let aside =
            pair.planned == displayed
            ? []
            : [
                "  compared by the identity that assesses this task, which is",
                "  not the encoding shown above: a lowering names its task from",
                "  one and planning decides whether to rerun it by the other.",
            ]
        guard !pair.recorded.isEmpty else {
            return aside + [
                "  diverged from a recorded identity that kept no components,",
                "  which is every record written before they were kept. This",
                "  task is locatable once it next executes.",
            ]
        }
        guard let recorded = IdentityTrace.decode(pair.recorded),
            let planned = IdentityTrace.decode(pair.planned)
        else {
            return aside + ["  <the compared identity components are not decodable>"]
        }
        let difference = IdentityTrace.difference(
            recorded: recorded, planned: planned)
        guard !difference.isEmpty else {
            // Reachable: the digests differ while the components render
            // alike, which says the difference is in bytes the rendering
            // elides rather than in the shape of the encoding.
            return aside
                + ["  diverged from the recorded identity in undisplayed bytes"]
        }
        return aside + ["  diverged from the recorded identity at"]
            + difference.map { "  " + $0 }
    }
}
