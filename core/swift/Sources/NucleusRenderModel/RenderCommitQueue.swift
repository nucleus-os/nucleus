// Phase 8.12 — Swift in-process transaction commit queue.
//
// The render server's incoming transaction queue: per-producer FIFO slots,
// latest-wins coalescing for shell-overlay frames, cross-context update-group
// blocking + ordered emission, and the ready-batch drain. Nothing imports this
// yet; the render server driving
// it (and the io_uring loop it shares a thread with) co-lands with the renderer
// move (10b).
//
// Dropped: the single-thread owner assertion and tracy plotting
// (runtime instrumentation, not queue semantics) and the OOM-allocation-failure
// paths (Swift collections do not surface allocation failure). The
// `isLatestWinsShellFrame` predicate is evaluated over the wire fields this
// dormant `Transaction` carries (group/completion-token/structural-empty/
// presentation-safe property writes); the animation-list and
// presentation-transition-request exclusions land when those wire fields are
// added to the envelope alongside the applier-side animation/transition work.

// MARK: - Frame envelope + group types

/// In-process render-server frame envelope wrapping one semantic transaction.
/// Mirrors `CommittedTransaction`.
public struct CommittedTransaction: Sendable {
    public var transaction: Transaction

    public init(transaction: Transaction) {
        self.transaction = transaction
    }
}

/// A producer's membership in an update group. Mirrors `GroupParticipant`.
public struct GroupParticipant: Equatable, Sendable {
    public var contextId: ContextID
    public var groupSeq: UInt32

    public init(contextId: ContextID, groupSeq: UInt32) {
        self.contextId = contextId
        self.groupSeq = groupSeq
    }
}

/// Update-group identity + close metadata. Mirrors `UpdateGroup`.
public struct UpdateGroup: Sendable {
    public var groupId: UInt64
    public var expectedCount: UInt32?
    public var transition: TransitionMetadata?

    public init(groupId: UInt64, expectedCount: UInt32?, transition: TransitionMetadata?) {
        self.groupId = groupId
        self.expectedCount = expectedCount
        self.transition = transition
    }
}

/// A producer-side close declaration for an update group. Mirrors
/// `GroupCloseEnvelope`.
public struct GroupCloseEnvelope: Sendable {
    public var groupId: UInt64
    public var participantCount: UInt32
    public var transition: TransitionMetadata?

    public init(groupId: UInt64, participantCount: UInt32, transition: TransitionMetadata?) {
        self.groupId = groupId
        self.participantCount = participantCount
        self.transition = transition
    }
}

/// A fully-arrived update group ready for the applier. Mirrors `ReadyGroup`.
public struct ReadyGroup: Sendable {
    public var meta: UpdateGroup
    public var txns: [CommittedTransaction]

    public init(meta: UpdateGroup, txns: [CommittedTransaction]) {
        self.meta = meta
        self.txns = txns
    }
}

/// One drained unit: an ungrouped single frame or a complete group. Mirrors
/// `ReadyBatch`.
public enum ReadyBatch: Sendable {
    case single(CommittedTransaction)
    case group(ReadyGroup)
}

// MARK: - Queue

/// The in-process transaction queue. A reference type — shared, mutable
/// single-thread structure. Mirrors `CommitQueue`.
public final class CommitQueue {
    public init() {}

    private struct Slot {
        var queue: [CommittedTransaction] = []
        var blockedGroupId: UInt64 = 0
    }

    private struct PendingGroup {
        var meta: UpdateGroup
        var participants: [GroupParticipant] = []
        var txns: [CommittedTransaction] = []

        func isReady() -> Bool {
            guard let expected = meta.expectedCount else { return false }
            return participants.count >= Int(expected)
        }
    }

    // Insertion-ordered iteration that the drain depends on.
    private var slotOrder: [ContextID] = []
    private var slots: [ContextID: Slot] = [:]
    private var groupOrder: [UInt64] = []
    private var pendingGroups: [UInt64: PendingGroup] = [:]

    /// Append a frame to its producer slot. A latest-wins shell-overlay frame
    /// first drops any trailing latest-wins frames already queued in that slot.
    /// Mirrors `commit`.
    public func commit(_ contextId: ContextID, _ frame: CommittedTransaction) {
        getOrCreateSlot(contextId)
        if contextId == shellOverlayContextId && isLatestWinsShellFrame(frame) {
            while let last = slots[contextId]!.queue.last, isLatestWinsShellFrame(last) {
                slots[contextId]!.queue.removeLast()
            }
        }
        slots[contextId]!.queue.append(frame)
    }

    /// Declare an update group's participant count + optional transition. A
    /// zero-participant close drops the group. Mirrors `closeGroup`.
    public func closeGroup(_ envelope: GroupCloseEnvelope) {
        if envelope.groupId == 0 { return }
        if envelope.participantCount == 0 {
            dropGroup(envelope.groupId)
            return
        }
        getOrCreatePendingGroup(envelope.groupId)
        pendingGroups[envelope.groupId]!.meta.expectedCount = envelope.participantCount
        if let metadata = envelope.transition {
            pendingGroups[envelope.groupId]!.meta.transition = metadata
        }
    }

    /// True when `contextId` has queued or in-flight grouped work. Mirrors
    /// `hasPending`.
    public func hasPending(_ contextId: ContextID) -> Bool {
        if let slot = slots[contextId], !slot.queue.isEmpty || slot.blockedGroupId != 0 {
            return true
        }
        for groupId in groupOrder {
            if pendingGroups[groupId]!.participants.contains(where: { $0.contextId == contextId }) {
                return true
            }
        }
        return false
    }

    /// Drain all globally ready batches. Ungrouped frames return as singles;
    /// grouped frames return only after a close declares the count and every
    /// participant has arrived. Mirrors `consumeReadyBatches`.
    public func consumeReadyBatches() -> [ReadyBatch] {
        var batches: [ReadyBatch] = []
        var progress = true
        while progress {
            progress = false
            if emitReadyGroups(&batches) { progress = true }
            if drainAvailableSlots(&batches) { progress = true }
            if emitReadyGroups(&batches) { progress = true }
        }
        return batches
    }

    /// Append the id of every producer with pending frames to `dest` (unique,
    /// capped at `limit`). Mirrors `collectPendingProducers`.
    public func collectPendingProducers(limit: Int) -> [ContextID] {
        var dest: [ContextID] = []
        for contextId in slotOrder {
            let slot = slots[contextId]!
            if !slot.queue.isEmpty || slot.blockedGroupId != 0 {
                appendUniqueProducer(&dest, contextId, limit: limit)
                if dest.count >= limit { return dest }
            }
        }
        for groupId in groupOrder {
            for participant in pendingGroups[groupId]!.participants {
                appendUniqueProducer(&dest, participant.contextId, limit: limit)
                if dest.count >= limit { return dest }
            }
        }
        return dest
    }

    // MARK: Drain internals

    private func drainAvailableSlots(_ batches: inout [ReadyBatch]) -> Bool {
        var madeProgress = false
        for contextId in slotOrder {
            if slots[contextId]!.blockedGroupId != 0 { continue }
            while !slots[contextId]!.queue.isEmpty {
                let groupId = slots[contextId]!.queue[0].transaction.groupId
                if groupId == 0 {
                    let frame = slots[contextId]!.queue.removeFirst()
                    batches.append(.single(frame))
                    madeProgress = true
                    continue
                }
                while !slots[contextId]!.queue.isEmpty,
                      slots[contextId]!.queue[0].transaction.groupId == groupId {
                    getOrCreatePendingGroup(groupId)
                    let frame = slots[contextId]!.queue.removeFirst()
                    addGroupedFrame(groupId, frame)
                    madeProgress = true
                }
                slots[contextId]!.blockedGroupId = groupId
                break
            }
        }
        return madeProgress
    }

    private func addGroupedFrame(_ groupId: UInt64, _ frame: CommittedTransaction) {
        pendingGroups[groupId]!.participants.append(GroupParticipant(
            contextId: frame.transaction.contextId, groupSeq: frame.transaction.groupSeq))
        pendingGroups[groupId]!.txns.append(frame)
    }

    private func emitReadyGroups(_ batches: inout [ReadyBatch]) -> Bool {
        var madeProgress = false
        var i = 0
        while i < groupOrder.count {
            let groupId = groupOrder[i]
            guard pendingGroups[groupId]!.isReady() else { i += 1; continue }

            var removed = pendingGroups.removeValue(forKey: groupId)!
            groupOrder.remove(at: i)
            sortGroupedTransactions(&removed.txns)
            batches.append(.group(ReadyGroup(meta: removed.meta, txns: removed.txns)))
            clearBlockedGroup(groupId)
            madeProgress = true
        }
        return madeProgress
    }

    private func getOrCreateSlot(_ contextId: ContextID) {
        if slots[contextId] == nil {
            slots[contextId] = Slot()
            slotOrder.append(contextId)
        }
    }

    private func getOrCreatePendingGroup(_ groupId: UInt64) {
        if pendingGroups[groupId] == nil {
            pendingGroups[groupId] = PendingGroup(meta: UpdateGroup(
                groupId: groupId, expectedCount: nil, transition: nil))
            groupOrder.append(groupId)
        }
    }

    private func clearBlockedGroup(_ groupId: UInt64) {
        for contextId in slotOrder where slots[contextId]!.blockedGroupId == groupId {
            slots[contextId]!.blockedGroupId = 0
        }
    }

    private func dropGroup(_ groupId: UInt64) {
        if pendingGroups.removeValue(forKey: groupId) != nil {
            groupOrder.removeAll { $0 == groupId }
        }
        for contextId in slotOrder {
            slots[contextId]!.queue.removeAll { $0.transaction.groupId == groupId }
            if slots[contextId]!.blockedGroupId == groupId {
                slots[contextId]!.blockedGroupId = 0
            }
        }
    }
}

// MARK: - Free helpers

/// Whether a shell-overlay frame is safe to drop in favor of a newer one: an
/// ungrouped, completion-token-free, structurally-empty frame whose property
/// updates touch only presentation-safe fields (no content/visual-style/shadow
/// change). Mirrors `isLatestWinsShellFrame` over the carried wire fields (see
/// the file header for the deferred animation/transition-request terms).
public func isLatestWinsShellFrame(_ frame: CommittedTransaction) -> Bool {
    let txn = frame.transaction
    if txn.groupId != 0 || txn.completionToken != 0 { return false }
    if !txn.created.isEmpty || !txn.inserted.isEmpty || !txn.removed.isEmpty ||
        !txn.detached.isEmpty || txn.propertyUpdates.isEmpty {
        return false
    }
    for update in txn.propertyUpdates {
        let contentChanged: Bool = { if case .unchanged = update.content { return false }; return true }()
        let visualStyleChanged: Bool = { if case .unchanged = update.visualStyle { return false }; return true }()
        let shadowChanged: Bool = { if case .unchanged = update.shadow { return false }; return true }()
        if contentChanged || visualStyleChanged || shadowChanged {
            return false
        }
    }
    return true
}

/// Stable insertion sort of grouped transactions by ascending `group_seq`.
/// Mirrors `sortGroupedTransactions`.
public func sortGroupedTransactions(_ items: inout [CommittedTransaction]) {
    var i = 1
    while i < items.count {
        var j = i
        while j > 0 && items[j - 1].transaction.groupSeq > items[j].transaction.groupSeq {
            items.swapAt(j - 1, j)
            j -= 1
        }
        i += 1
    }
}

/// Append `id` to `dest` if absent and under `limit`. Mirrors
/// `appendUniqueProducer`.
public func appendUniqueProducer(_ dest: inout [ContextID], _ id: ContextID, limit: Int) {
    if dest.contains(id) { return }
    if dest.count >= limit { return }
    dest.append(id)
}
