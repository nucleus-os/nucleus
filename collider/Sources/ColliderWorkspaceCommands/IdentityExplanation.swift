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

    /// The collected components, rendered one component per line beneath the
    /// task that encoded them.
    package func report() -> [String] {
        let collected = encoded.withLock { $0 }
        guard !collected.isEmpty else {
            guard let selection else { return [] }
            return ["identity  no planned task contains \"\(selection)\""]
        }
        var lines: [String] = []
        for task in collected.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            lines.append("identity  \(task.rawValue)")
            guard let nodes = IdentityTrace.decode(collected[task] ?? []) else {
                lines.append("  <identity components are not decodable>")
                continue
            }
            lines += IdentityTrace.render(nodes, indent: 1)
        }
        return lines
    }
}
