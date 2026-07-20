@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderCommitQueueTests {
    func frame(_ ctx: ContextID, group: UInt64, seq: UInt32) -> CommittedTransaction {
        var txn = Transaction(contextId: ctx)
        txn.groupId = group
        txn.groupSeq = seq
        return CommittedTransaction(transaction: txn)
    }

    /// A latest-wins shell frame: a single presentation-safe property update.
    func shellPresentationFrame() -> CommittedTransaction {
        var txn = Transaction(contextId: shellOverlayContextId)
        var pu = LayerPropertyUpdate(nodeId: 1)
        pu.opacity = 0.5
        txn.propertyUpdates.append(pu)
        return CommittedTransaction(transaction: txn)
    }

    @Test func renderCommitQueue() {
        // Ungrouped frame → one single batch.
        do {
            let q = CommitQueue()
            let ctx = ContextID(raw: 1)
            q.commit(ctx, frame(ctx, group: 0, seq: 0))
            let batches = q.consumeReadyBatches()
            #expect(batches.count == 1, "ungrouped-one-batch")
            if case .single(let f) = batches[0] { #expect(f.transaction.contextId == ctx, "ungrouped-context") }
            else { Issue.record("ungrouped-is-single") }
        }

        // Grouped frames held until close, then drained in group_seq order, and
        // the ungrouped frame from the same producer follows.
        do {
            let q = CommitQueue()
            let c1 = ContextID(raw: 1)
            let c2 = ContextID(raw: 2)
            q.commit(c1, frame(c1, group: 7, seq: 2))
            q.commit(c1, frame(c1, group: 0, seq: 0))
            q.commit(c2, frame(c2, group: 7, seq: 1))

            let before = q.consumeReadyBatches()
            #expect(before.isEmpty, "grouped-held-before-close")
            #expect(q.hasPending(c1) && q.hasPending(c2), "grouped-has-pending")

            q.closeGroup(GroupCloseEnvelope(groupId: 7, participantCount: 2, transition: nil))
            let after = q.consumeReadyBatches()
            #expect(after.count == 2, "grouped-two-batches-after-close")
            if case .group(let g) = after[0] {
                #expect(g.meta.groupId == 7 && g.txns.count == 2, "grouped-group-meta")
                #expect(g.txns[0].transaction.groupSeq == 1 && g.txns[1].transaction.groupSeq == 2,
                      "grouped-seq-order")
            } else { Issue.record("grouped-first-is-group") }
            if case .single(let f) = after[1] { #expect(f.transaction.contextId == c1, "grouped-single-follows") }
            else { Issue.record("grouped-second-is-single") }
        }

        // Zero-participant close drops the pending group entirely.
        do {
            let q = CommitQueue()
            let c1 = ContextID(raw: 1)
            q.commit(c1, frame(c1, group: 11, seq: 1))
            q.closeGroup(GroupCloseEnvelope(groupId: 11, participantCount: 0, transition: nil))
            #expect(q.consumeReadyBatches().isEmpty, "zero-close-no-batches")
            #expect(!q.hasPending(c1), "zero-close-not-pending")
        }

        // Group transition metadata rides on the ready batch.
        do {
            let q = CommitQueue()
            let c1 = ContextID(raw: 1)
            q.commit(c1, frame(c1, group: 19, seq: 1))
            let metadata = TransitionMetadata(type: .push, subtype: .fromRight,
                                              durationNs: 240_000_000, timing: .easeInEaseOut)
            q.closeGroup(GroupCloseEnvelope(groupId: 19, participantCount: 1, transition: metadata))
            let batches = q.consumeReadyBatches()
            #expect(batches.count == 1, "metadata-one-batch")
            if case .group(let g) = batches[0] {
                #expect(g.meta.transition.map { equivalentTransitionMetadata($0, metadata) } == true,
                      "metadata-carried")
            } else { Issue.record("metadata-is-group") }
        }

        // Context ids beyond the legacy fixed slot range are accepted.
        do {
            let q = CommitQueue()
            let high = ContextID(raw: 4096)
            q.commit(high, frame(high, group: 0, seq: 0))
            let batches = q.consumeReadyBatches()
            #expect(batches.count == 1, "high-context-one-batch")
        }

        // Latest-wins shell coalescing: a second presentation-only shell frame
        // drops the first; a content-changing frame does not coalesce.
        do {
            let q = CommitQueue()
            q.commit(shellOverlayContextId, shellPresentationFrame())
            q.commit(shellOverlayContextId, shellPresentationFrame())
            // Both were latest-wins → only the newest survives → one batch.
            let batches = q.consumeReadyBatches()
            #expect(batches.count == 1, "shell-coalesce-latest-wins")

            // A frame that changes content is NOT latest-wins.
            var contentTxn = Transaction(contextId: shellOverlayContextId)
            var pu = LayerPropertyUpdate(nodeId: 1)
            pu.content = .paint(PaintContentHandle(raw: 9))
            contentTxn.propertyUpdates.append(pu)
            #expect(!isLatestWinsShellFrame(CommittedTransaction(transaction: contentTxn)),
                  "shell-content-not-latest-wins")
            // A grouped frame is never latest-wins.
            #expect(!isLatestWinsShellFrame(frame(shellOverlayContextId, group: 3, seq: 0)),
                  "shell-grouped-not-latest-wins")
        }

        // collectPendingProducers returns each pending producer once, capped.
        do {
            let q = CommitQueue()
            let c1 = ContextID(raw: 1)
            let c2 = ContextID(raw: 2)
            q.commit(c1, frame(c1, group: 0, seq: 0))
            q.commit(c2, frame(c2, group: 0, seq: 0))
            let producers = q.collectPendingProducers(limit: 8)
            #expect(producers.count == 2 && producers.contains(c1) && producers.contains(c2),
                  "collect-producers")
            #expect(q.collectPendingProducers(limit: 1).count == 1, "collect-producers-capped")
        }
    }
}
