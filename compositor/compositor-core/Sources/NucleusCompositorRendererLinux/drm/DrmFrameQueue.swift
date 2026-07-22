// DrmOutput frame-pacing value logic: presentation timing, the mailbox queue
// policy, and rendered-frame commit ordering.
//
// These portable value types cover: the in-flight present-id/timestamp scalars, the
// mailbox pending-frame queue (generation cursor, round-robin render-slot
// selection, newest-ready selection, backlog trimming), and the rendered-frame
// commit ordering (close in submission order, supersede the rest). The Vulkan
// texture allocation, fd lifecycle, DisplayLink prediction, and presentation
// correlation are owned by DrmOutput and RendererRuntime. Here a frame is keyed on
// its render-slot index and renderReadyFd, and removed frames are returned to the
// caller so it can close their fds.

// MARK: - Frame timing

/// Per-frame presentation timestamps. Mirrors `MailboxState.FrameTiming`.
struct FrameTiming: Sendable, Equatable {
    var targetPresentNs: UInt64?
    var predictedPresentNs: UInt64
    var submitNs: UInt64
    var frameOffset: UInt32 = 0
}

/// The in-flight present-id + predicted/target/submit timestamps for the
/// currently-submitted scanout commit. The DisplayLink-facing prediction is
/// integration that lands separately.
struct PresentationTiming: Sendable, Equatable {
    private(set) var inFlightPresentId: UInt64?
    private(set) var inFlightTargetPresentNs: UInt64?
    private(set) var inFlightPredictedPresentNs: UInt64?
    private(set) var inFlightSubmitNs: UInt64 = 0

    /// Record a submitted commit's timing. A `presentId` of 0 maps to nil (the
    /// "no present id" sentinel).
    mutating func recordSubmitted(
        presentId: UInt64,
        targetPresentNs: UInt64?,
        predictedPresentNs: UInt64?,
        submitNs: UInt64
    ) {
        inFlightPresentId = presentId == 0 ? nil : presentId
        inFlightTargetPresentNs = targetPresentNs
        inFlightPredictedPresentNs = predictedPresentNs
        inFlightSubmitNs = submitNs
    }

    mutating func clearInFlight() {
        inFlightPresentId = nil
        inFlightTargetPresentNs = nil
        inFlightPredictedPresentNs = nil
        inFlightSubmitNs = 0
    }

    var presentId: UInt64? { inFlightPresentId }
    var targetPresentNs: UInt64? { inFlightTargetPresentNs }
    var predictedPresentNs: UInt64? { inFlightPredictedPresentNs }
}

// MARK: - Present policy

public enum RendererPresentPolicy: Sendable, Equatable {
    case vsync
    case mailboxLatestWins

    var label: String {
        switch self {
        case .vsync: return "vsync"
        case .mailboxLatestWins: return "mailbox_latest_wins"
        }
    }

}

// MARK: - Mailbox queue

/// A mailbox pending frame, keyed on its render-slot index + generation. The
/// `renderReadyFd` is the GPU-completion fence the caller polls/closes.
struct PendingMailboxFrame: Sendable, Equatable {
    var textureIndex: Int
    var generation: UInt64
    var renderReadyFd: Int32
    var timing: FrameTiming
    var gpuCompleted: Bool = false
    var copyPending: Bool = false
}

/// The mailbox-mode pending-frame queue + render-slot round-robin. Pure policy:
/// the Vulkan render targets it indexes and the fd closing are the caller's.
struct MailboxQueue: Sendable {
    static let renderTargetCount = 2

    var policy: RendererPresentPolicy = .vsync
    private(set) var pending: [PendingMailboxFrame] = []
    private(set) var cursor: Int = 0
    private(set) var generation: UInt64 = 0

    init(policy: RendererPresentPolicy = .vsync) { self.policy = policy }

    var pendingCount: Int { pending.count }

    func frameUsesTexture(_ index: Int) -> Bool {
        pending.contains { $0.textureIndex == index }
    }

    var hasAvailableTexture: Bool {
        (0..<MailboxQueue.renderTargetCount).contains { !frameUsesTexture($0) }
    }

    /// Any frame still rendering (not yet GPU-complete and not a scanout copy).
    var hasRenderInFlight: Bool {
        pending.contains { !$0.copyPending && !$0.gpuCompleted }
    }

    /// Round-robin pick of the next free render-slot index, advancing the cursor.
    /// nil when all slots are in use. Mirrors `selectTexture`'s index logic.
    mutating func selectTextureIndex() -> Int? {
        for attempt in 0..<MailboxQueue.renderTargetCount {
            let index = (cursor + attempt) % MailboxQueue.renderTargetCount
            if frameUsesTexture(index) { continue }
            cursor = (index + 1) % MailboxQueue.renderTargetCount
            return index
        }
        return nil
    }

    /// Newest ready (GPU-complete, not a pending copy) frame, scanning from the
    /// back. Mirrors `newestReady`.
    func newestReady() -> PendingMailboxFrame? {
        pending.last { $0.gpuCompleted && !$0.copyPending }
    }

    /// Newest non-copy frame's ready fd, or -1. Mirrors `newestPollFd`.
    func newestPollFd() -> Int32 {
        for frame in pending.reversed() where !frame.copyPending { return frame.renderReadyFd }
        return -1
    }

    func frameIndex(forGeneration generation: UInt64) -> Int? {
        pending.firstIndex { $0.generation == generation }
    }

    var nextGeneration: UInt64 { generation &+ 1 }

    mutating func noteInstalled(_ generation: UInt64) {
        self.generation = generation
    }

    /// Append a frame and advance the generation cursor to it.
    mutating func append(_ frame: PendingMailboxFrame) {
        pending.append(frame)
        noteInstalled(frame.generation)
    }

    mutating func popPending() -> PendingMailboxFrame? {
        pending.isEmpty ? nil : pending.removeLast()
    }

    @discardableResult
    mutating func removeAt(_ index: Int) -> PendingMailboxFrame {
        pending.remove(at: index)
    }

    mutating func setCopyPending(at index: Int, _ value: Bool) {
        pending[index].copyPending = value
    }

    /// Mark the frame at `generation` GPU-complete (the pure stand-in for the
    /// fd-readability poll the integration does).
    mutating func markGpuCompleted(generation: UInt64) {
        if let i = frameIndex(forGeneration: generation) { pending[i].gpuCompleted = true }
    }

    mutating func bumpGenerationOnDrain() {
        generation &+= 1
    }

    /// Drop all ready (GPU-complete, non-copy) frames except the newest ready
    /// generation, returning the removed frames for fd cleanup. Mirrors
    /// `trimMailboxBacklog`.
    mutating func trimToNewestReady() -> [PendingMailboxFrame] {
        var keepGeneration: UInt64?
        for frame in pending where !frame.copyPending && frame.gpuCompleted {
            keepGeneration = frame.generation
        }
        guard let keep = keepGeneration else { return [] }
        return removeReady(where: { $0 != keep })
    }

    /// Drop all ready frames whose generation differs from `generation`,
    /// returning the removed frames. Mirrors `dropReadyMailboxFramesBefore`.
    mutating func dropReadyFrames(exceptGeneration generation: UInt64) -> [PendingMailboxFrame] {
        removeReady(where: { $0 != generation })
    }

    private mutating func removeReady(where shouldRemove: (UInt64) -> Bool) -> [PendingMailboxFrame] {
        var removed: [PendingMailboxFrame] = []
        var index = 0
        while index < pending.count {
            let frame = pending[index]
            if !frame.copyPending && frame.gpuCompleted && shouldRemove(frame.generation) {
                removed.append(pending.remove(at: index))
                continue
            }
            index += 1
        }
        return removed
    }
}

// MARK: - Rendered-frame queue

/// A rendered (vsync-path) scanout frame awaiting page flip.
struct PendingRenderedFrame: Sendable, Equatable {
    var bufferIndex: Int
    var fbId: UInt32
    var modifier: UInt64
    var generation: UInt64
    var renderReadyFd: Int32
    var timing: FrameTiming
    var gpuCompleted: Bool = false
    var mailboxSourceGeneration: UInt64?
}

/// The vsync-path rendered-frame queue. The commit ordering invariant: frames
/// are closed in submission order; the committed generation's frame presents and
/// every earlier queued frame is superseded (dropped). Mirrors `FrameQueue`.
struct RenderedFrameQueue: Sendable {
    private(set) var pending: [PendingRenderedFrame] = []

    var count: Int { pending.count }

    /// Install a frame. In vsync mode the queue holds at most one frame, so any
    /// existing entries are returned as superseded for the caller to close.
    mutating func install(_ frame: PendingRenderedFrame, vsync: Bool) -> [PendingRenderedFrame] {
        var superseded: [PendingRenderedFrame] = []
        if vsync {
            superseded = pending
            pending.removeAll(keepingCapacity: true)
        }
        pending.append(frame)
        return superseded
    }

    /// Newest queued frame's ready fd, or -1.
    func newestPollFd() -> Int32 {
        pending.last?.renderReadyFd ?? -1
    }

    /// Empty the queue, returning every frame for the caller to close.
    mutating func drain() -> [PendingRenderedFrame] {
        let all = pending
        pending.removeAll(keepingCapacity: true)
        return all
    }

    /// Commit the frame at `generation`: it and all earlier queued frames leave
    /// the queue in submission order. Returns the committed frame plus the
    /// earlier frames that were superseded (dropped). A no-op (nil committed,
    /// empty dropped) when the generation isn't queued. Mirrors
    /// `commitPendingRenderedFrame`.
    mutating func commit(generation: UInt64) -> (committed: PendingRenderedFrame?, dropped: [PendingRenderedFrame]) {
        guard let endIndex = pending.firstIndex(where: { $0.generation == generation }) else {
            return (nil, [])
        }
        var dropped: [PendingRenderedFrame] = []
        var committed: PendingRenderedFrame?
        for position in 0...endIndex {
            let frame = pending[position]
            if position == endIndex { committed = frame } else { dropped.append(frame) }
        }
        pending.removeSubrange(0...endIndex)
        return (committed, dropped)
    }
}
