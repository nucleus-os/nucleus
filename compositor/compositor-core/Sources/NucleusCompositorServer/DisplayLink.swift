import Glibc

// The per-output frame scheduler. Owned by `Display` (one per
// output); the compositor display registry (`DesktopLayout`) drives it. The
// behavioral contract — frame-demand consumption, present-id issuance,
// predicted-present timing, and continuous-demand bits — is preserved
// exactly against the frame-pacing fixtures.
//
// The composition root publishes the scheduler's samples to Tracy because this
// cxx-free model module must not import the C++ Tracy bridge. Submit/present
// crossings also open and close one discontinuous frame range per output.

public enum PresentSource: Sendable, Equatable {
    case drmPageFlip
    case vkPresentTiming
    case synthetic
}

public struct RedrawReasons: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let surfaceDamage = Self(rawValue: 1 << 0)
    public static let animation = Self(rawValue: 1 << 1)
    public static let cursor = Self(rawValue: 1 << 2)
    public static let shellOverlay = Self(rawValue: 1 << 3)
    public static let outputChange = Self(rawValue: 1 << 4)
    public static let screencopy = Self(rawValue: 1 << 5)
    public static let lockTransition = Self(rawValue: 1 << 6)
    public static let recovery = Self(rawValue: 1 << 7)
}

public enum OutputRedrawState: Sendable, Equatable {
    case idle
    case queued(RedrawReasons)
    case rendering(frameBuildID: UInt64, pending: RedrawReasons)
    case awaitingPresentation(submissionID: UInt64, pending: RedrawReasons)
    case deferredUntil(UInt64, RedrawReasons)
    case suspended(RedrawReasons)
}

public struct PresentReport: Sendable, Equatable {
    public var source: PresentSource
    public var presentationNs: UInt64
    public var presentID: UInt64?
    public var targetPresentNs: UInt64?
    public var predictedPresentNs: UInt64?
    public var refreshIntervalNs: UInt64?

    public init(
        source: PresentSource,
        presentationNs: UInt64,
        presentID: UInt64? = nil,
        targetPresentNs: UInt64? = nil,
        predictedPresentNs: UInt64? = nil,
        refreshIntervalNs: UInt64? = nil
    ) {
        self.source = source
        self.presentationNs = presentationNs
        self.presentID = presentID
        self.targetPresentNs = targetPresentNs
        self.predictedPresentNs = predictedPresentNs
        self.refreshIntervalNs = refreshIntervalNs
    }
}

private func nsNow() -> UInt64 {
    var ts = timespec()
    unsafe clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

private func satAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? .max : sum
}

private func satMul(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (product, overflow) = a.multipliedReportingOverflow(by: b)
    return overflow ? .max : product
}

public struct DisplayLink: Sendable {
    /// One-bit-per-source tracking for continuous demand. Each source toggles
    /// its own slot so turning one off doesn't cancel another's demand.
    public struct ContinuousDemand: Sendable, Equatable {
        public var animation: Bool = false
        public var notification: Bool = false
        public var screenshot: Bool = false
        public var background: Bool = false

        public init(
            animation: Bool = false,
            notification: Bool = false,
            screenshot: Bool = false,
            background: Bool = false
        ) {
            self.animation = animation
            self.notification = notification
            self.screenshot = screenshot
            self.background = background
        }

        public func any() -> Bool {
            animation || notification || screenshot || background
        }
    }

    public struct OutputTimelineSample: Sendable, Equatable {
        public var deadlineNs: UInt64
        public var predictedPresentNs: UInt64
        public var targetPresentNs: UInt64?
        public var lastPresentID: UInt64
        public var nextPresentID: UInt64
        public var source: PresentSource
        public var presentationTimeSeconds: Double
        public var refreshIntervalNs: UInt64
    }

    public var refreshIntervalNs: UInt64
    public var lastPresentationNs: Int64
    public var outputTag: String
    public var attachedSource: PresentSource = .drmPageFlip
    public var lastPresentID: UInt64 = 0
    public var lastAckedPresentID: UInt64 = 0
    public var submittedFrameOpen: Bool = false
    public var requested: Bool = false
    public var frameDue: Bool = false
    /// The vblank selected when transient frame demand first becomes pending.
    /// This must remain fixed until the demand is consumed: recomputing the next
    /// predicted vblank during the reactor's due check moves the target forward
    /// after every deadline wake and makes a queued frame impossible to render.
    private var frameTargetPresentNs: UInt64? = nil
    public var frameDeadlineNs: UInt64? = nil
    public var continuous: ContinuousDemand = .init()

    public init(refreshIntervalNs: UInt64, outputTag: String = "bootstrap") {
        self.refreshIntervalNs = refreshIntervalNs
        self.lastPresentationNs = Int64(bitPattern: nsNow())
        self.outputTag = outputTag
    }

    public mutating func attachSource(_ source: PresentSource) {
        attachedSource = source
    }

    public mutating func request() {
        requested = true
    }

    public mutating func cancelRequest() {
        requested = false
    }

    public mutating func suspend() {
        requested = false
        frameDue = false
        frameTargetPresentNs = nil
        frameDeadlineNs = nil
        cancelSubmittedFrame()
    }

    /// Drop the old vblank phase. The first page flip after recovery replaces
    /// this bootstrap sample with the new kernel clock observation.
    public mutating func resetPresentationPhase() {
        lastPresentationNs = Int64(bitPattern: nsNow())
        lastAckedPresentID = lastPresentID
        frameTargetPresentNs = nil
        cancelSubmittedFrame()
    }

    public mutating func updateRefreshInterval(_ refreshIntervalNs: UInt64) {
        self.refreshIntervalNs = refreshIntervalNs
    }

    /// Mark a one-shot frame need. Idempotent within a frame.
    public mutating func requestFrame() {
        if frameTargetPresentNs == nil {
            frameTargetPresentNs = predictedPresentNs(0)
        }
        frameDue = true
    }

    /// Schedule a one-shot frame for the earliest requested monotonic deadline.
    public mutating func requestFrameDeadline(_ deadlineNs: UInt64) {
        if let current = frameDeadlineNs {
            frameDeadlineNs = min(current, deadlineNs)
        } else {
            frameDeadlineNs = deadlineNs
        }
    }

    /// Consume scheduler demand for a frame accepted by the present primitive.
    /// Returns whether transient, continuous, or due scheduled demand was
    /// present and clears transient state.
    public mutating func consumeFrameDemand() -> Bool {
        let nowNs = Int64(bitPattern: nsNow())
        let scheduledFrameDue = frameDeadlineDue(nowNs)
        let had = frameDue || continuous.any() || scheduledFrameDue
        frameDue = false
        frameTargetPresentNs = nil
        if scheduledFrameDue { frameDeadlineNs = nil }
        return had
    }

    public func hasFrameRequest() -> Bool {
        frameDue || continuous.any()
            || frameDeadlineDue(Int64(bitPattern: nsNow()))
    }

    public mutating func nextPresentID() -> UInt64 {
        lastPresentID = lastPresentID &+ 1
        if lastPresentID == 0 { lastPresentID = 1 }
        return lastPresentID
    }

    public func peekNextPresentID() -> UInt64 {
        let next = lastPresentID &+ 1
        return next == 0 ? 1 : next
    }

    /// Open the per-output submitted-frame range for a frame accepted by the
    /// present primitive. The range closes when `presented` observes
    /// presentation completion.
    public mutating func beginSubmittedFrame() {
        if submittedFrameOpen { cancelSubmittedFrame() }
        submittedFrameOpen = true
    }

    public mutating func presented(_ report: PresentReport) {
        attachedSource = report.source
        lastPresentationNs = Int64(bitPattern: report.presentationNs)
        if let presentID = report.presentID {
            lastAckedPresentID = max(lastAckedPresentID, presentID)
            if presentID > lastPresentID { lastPresentID = presentID }
        }
        if let refreshIntervalNs = report.refreshIntervalNs {
            self.refreshIntervalNs = refreshIntervalNs
        }
        closeSubmittedFrame()
    }

    public mutating func cancelSubmittedFrame() {
        guard submittedFrameOpen else { return }
        closeSubmittedFrame()
    }

    public func predictedPresentNs(_ frameOffset: UInt32) -> UInt64 {
        let intervalNs = max(refreshIntervalNs, 1)
        var predicted = UInt64(max(lastPresentationNs &+ Int64(bitPattern: intervalNs), 0))
        let now = nsNow()
        if predicted <= now {
            let elapsedNs = now - predicted
            let missedIntervals = elapsedNs / intervalNs + 1
            predicted = satAdd(predicted, satMul(missedIntervals, intervalNs))
        }
        predicted = satAdd(predicted, satMul(UInt64(frameOffset), intervalNs))
        return predicted
    }

    public func targetPresentNs() -> UInt64? {
        if !requested && !hasFrameRequest() { return nil }
        return currentDeadlineNs()
    }

    public func nextDeadlineNs() -> Int64 {
        Int64(bitPattern: currentDeadlineNs())
    }

    private func currentDeadlineNs() -> UInt64 {
        let vsyncDeadline = frameTargetPresentNs
            ?? predictedPresentNs(0)
        if let deadline = frameDeadlineNs {
            return min(vsyncDeadline, deadline)
        }
        return vsyncDeadline
    }

    private mutating func closeSubmittedFrame() {
        guard submittedFrameOpen else { return }
        submittedFrameOpen = false
    }

    public func msUntilDeadline() -> Int32 {
        let remainingNs = nextDeadlineNs() - Int64(bitPattern: nsNow())
        if remainingNs <= 0 { return 0 }
        return Int32(clamping: remainingNs / 1_000_000)
    }

    public func presentationTimeSeconds() -> Double {
        Double(currentDeadlineNs()) / 1_000_000_000
    }

    public func sampleTimeline() -> OutputTimelineSample {
        let deadline = currentDeadlineNs()
        return OutputTimelineSample(
            deadlineNs: deadline,
            predictedPresentNs: predictedPresentNs(0),
            targetPresentNs: targetPresentNs(),
            lastPresentID: lastPresentID,
            nextPresentID: peekNextPresentID(),
            source: attachedSource,
            presentationTimeSeconds: Double(deadline) / 1_000_000_000,
            refreshIntervalNs: refreshIntervalNs
        )
    }

    private func frameDeadlineDue(_ nowNs: Int64) -> Bool {
        guard let deadline = frameDeadlineNs else { return false }
        return nowNs >= Int64(bitPattern: deadline)
    }

}
