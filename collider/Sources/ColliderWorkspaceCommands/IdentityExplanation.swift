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
    private let recorded = Mutex<[TaskID: [UInt8]]>([:])

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

    /// The components a prior execution recorded, for a task planning is
    /// about to rerun because they no longer match.
    package var recordedObserver: (@Sendable (TaskID, [UInt8]) -> Void)? {
        guard let selection else { return nil }
        return { [self] task, bytes in
            guard task.rawValue.contains(selection) else { return }
            recorded.withLock { if $0[task] == nil { $0[task] = bytes } }
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
        let priors = recorded.withLock { $0 }
        var lines: [String] = []
        for task in collected.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            lines.append("identity  \(task.rawValue)")
            guard let nodes = IdentityTrace.decode(collected[task] ?? []) else {
                lines.append("  <identity components are not decodable>")
                continue
            }
            lines += IdentityTrace.render(nodes, indent: 1)
            lines += divergence(of: task, planned: nodes, priors: priors)
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
        planned: [IdentityTrace.Node],
        priors: [TaskID: [UInt8]]
    ) -> [String] {
        guard let bytes = priors[task] else { return [] }
        guard !bytes.isEmpty else {
            return [
                "  diverged from a recorded identity that kept no components,",
                "  which is every record written before they were kept. This",
                "  task is locatable once it next executes.",
            ]
        }
        guard let recorded = IdentityTrace.decode(bytes) else {
            return ["  <recorded identity components are not decodable>"]
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
