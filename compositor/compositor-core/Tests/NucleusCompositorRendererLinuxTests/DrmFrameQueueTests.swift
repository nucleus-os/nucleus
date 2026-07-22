import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux

// — presentation timing scalars, the mailbox queue policy (round-robin slot pick,
// newest-ready, backlog trim), and the rendered-frame commit ordering — against
// the behavior of the Zig PresentationTiming / MailboxState / FrameQueue. Fully
// hardware-independent.
@Suite struct DrmFrameQueueTests {
    static func timing(_ predicted: UInt64) -> FrameTiming {
        FrameTiming(targetPresentNs: nil, predictedPresentNs: predicted, submitNs: predicted)
    }

    static func mailbox(_ gen: UInt64, slot: Int, fd: Int32 = 100) -> PendingMailboxFrame {
        PendingMailboxFrame(textureIndex: slot, generation: gen, renderReadyFd: fd, timing: timing(gen))
    }

    static func rendered(_ gen: UInt64, buffer: Int) -> PendingRenderedFrame {
        PendingRenderedFrame(bufferIndex: buffer, fbId: UInt32(gen), modifier: 0,
                             generation: gen, renderReadyFd: Int32(gen), timing: timing(gen))
    }

    @Test func presentPolicy() {
    }

    @Test func presentationTiming() {
        var pt = PresentationTiming()
        #expect(pt.presentId == nil && pt.targetPresentNs == nil, "pt-fresh")
        pt.recordSubmitted(presentId: 42, targetPresentNs: 1000, predictedPresentNs: 900, submitNs: 800)
        #expect(pt.presentId == 42 && pt.targetPresentNs == 1000 && pt.predictedPresentNs == 900, "pt-record")
        pt.recordSubmitted(presentId: 0, targetPresentNs: nil, predictedPresentNs: nil, submitNs: 1)
        #expect(pt.presentId == nil, "pt-zero-id-nil")
        pt.recordSubmitted(presentId: 7, targetPresentNs: 1, predictedPresentNs: 1, submitNs: 1)
        pt.clearInFlight()
        #expect(pt.presentId == nil && pt.targetPresentNs == nil && pt.inFlightSubmitNs == 0, "pt-clear")
    }

    @Test func mailboxQueue() {
        // Round-robin slot selection.
        var mq = MailboxQueue(policy: .mailboxLatestWins)
        #expect(mq.selectTextureIndex() == 0, "mq-slot-0")
        mq.append(Self.mailbox(1, slot: 0))
        #expect(mq.selectTextureIndex() == 1, "mq-slot-1")
        mq.append(Self.mailbox(2, slot: 1))
        // Both slots in use → no free slot.
        #expect(mq.selectTextureIndex() == nil, "mq-no-free-slot")
        #expect(mq.hasRenderInFlight, "mq-render-in-flight")
        #expect(!mq.hasAvailableTexture, "mq-no-available")

        // Newest-ready + generation cursor.
        #expect(mq.newestReady() == nil, "mq-none-ready")           // neither GPU-complete
        mq.markGpuCompleted(generation: 1)
        mq.markGpuCompleted(generation: 2)
        #expect(mq.newestReady()?.generation == 2, "mq-newest-ready")
        #expect(mq.generation == 2, "mq-generation-cursor")
        #expect(mq.nextGeneration == 3, "mq-next-generation")

        // Trim backlog keeps only newest ready.
        let trimmed = mq.trimToNewestReady()
        #expect(trimmed.count == 1 && trimmed[0].generation == 1, "mq-trim-drops-older")
        #expect(mq.pendingCount == 1 && mq.newestReady()?.generation == 2, "mq-trim-keeps-newest")

        // dropReadyFrames(exceptGeneration:) on a fresh queue.
        var mq2 = MailboxQueue(policy: .mailboxLatestWins)
        mq2.append(Self.mailbox(10, slot: 0)); mq2.append(Self.mailbox(11, slot: 1))
        mq2.markGpuCompleted(generation: 10); mq2.markGpuCompleted(generation: 11)
        let dropped = mq2.dropReadyFrames(exceptGeneration: 11)
        #expect(dropped.count == 1 && dropped[0].generation == 10 && mq2.pendingCount == 1, "mq-drop-except")

        // copyPending excludes a frame from ready/poll selection.
        var mq3 = MailboxQueue(policy: .mailboxLatestWins)
        mq3.append(Self.mailbox(20, slot: 0, fd: 55))
        mq3.markGpuCompleted(generation: 20)
        if let idx = mq3.frameIndex(forGeneration: 20) { mq3.setCopyPending(at: idx, true) }
        #expect(mq3.newestReady() == nil && mq3.newestPollFd() == -1, "mq-copy-pending-excluded")
    }

    @Test func renderedFrameQueue() {
        // vsync holds one; commit ordering.
        var rq = RenderedFrameQueue()
        let s1 = rq.install(Self.rendered(1, buffer: 0), vsync: true)
        #expect(s1.isEmpty && rq.count == 1, "rq-install-first")
        let s2 = rq.install(Self.rendered(2, buffer: 1), vsync: true)
        #expect(s2.count == 1 && s2[0].generation == 1 && rq.count == 1, "rq-vsync-supersedes")

        // Mailbox-mode queue (vsync=false) accumulates; commit drops earlier.
        var rq2 = RenderedFrameQueue()
        _ = rq2.install(Self.rendered(1, buffer: 0), vsync: false)
        _ = rq2.install(Self.rendered(2, buffer: 1), vsync: false)
        _ = rq2.install(Self.rendered(3, buffer: 0), vsync: false)
        #expect(rq2.newestPollFd() == 3, "rq-newest-fd")
        let result = rq2.commit(generation: 2)
        #expect(result.committed?.generation == 2, "rq-commit-target")
        #expect(result.dropped.count == 1 && result.dropped[0].generation == 1, "rq-commit-drops-earlier")
        #expect(rq2.count == 1 && rq2.pending[0].generation == 3, "rq-commit-keeps-later")
        // Committing an absent generation is a no-op.
        let noop = rq2.commit(generation: 999)
        #expect(noop.committed == nil && noop.dropped.isEmpty && rq2.count == 1, "rq-commit-absent-noop")
    }
}
