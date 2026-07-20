@_spi(NucleusPlatform) import NucleusRenderer
@_spi(NucleusPlatform) import NucleusCompositorRendererLinux

struct AcceptedCompositeFrame: Equatable {
    let frame: RenderFrameTelemetry
    let atomicCommitAcceptedNs: UInt64
}

struct PresentedCompositeFrame: Equatable {
    let frame: RenderFrameTelemetry
    let atomicCommitAcceptedNs: UInt64
    let pageflipNs: UInt64
    let fenceTelemetry: CompositeFenceTelemetry
}

/// Joins the three independently delivered facts for a composite frame without
/// relying on callback order. Direct-scanout serial zero is deliberately outside
/// this state machine. A completion for an unknown key permanently discards that
/// key so a late fact cannot become associated with a future frame.
struct PresentationTelemetryCorrelator {
    private struct Key: Hashable {
        let outputID: UInt64
        let frameSerial: UInt64
    }

    private var submissions: [Key: UInt64] = [:]
    private var frames: [Key: RenderFrameTelemetry] = [:]
    private var acceptedFrames: [Key: AcceptedCompositeFrame] = [:]
    private var discardedCompletions: Set<Key> = []

    mutating func noteSubmission(
        outputID: UInt64, frameSerial: UInt64, atomicCommitAcceptedNs: UInt64
    ) -> AcceptedCompositeFrame? {
        guard frameSerial != 0 else { return nil }
        let key = Key(outputID: outputID, frameSerial: frameSerial)
        guard !discardedCompletions.contains(key), submissions[key] == nil,
              acceptedFrames[key] == nil
        else { return nil }
        submissions[key] = atomicCommitAcceptedNs
        return acceptIfComplete(key)
    }

    mutating func noteFrame(_ frame: RenderFrameTelemetry) -> AcceptedCompositeFrame? {
        guard frame.frameSerial != 0 else { return nil }
        let key = Key(outputID: frame.outputID, frameSerial: frame.frameSerial)
        guard !discardedCompletions.contains(key), frames[key] == nil,
              acceptedFrames[key] == nil
        else { return nil }
        frames[key] = frame
        return acceptIfComplete(key)
    }

    mutating func notePageflip(
        outputID: UInt64, frameSerial: UInt64, pageflipNs: UInt64,
        fenceTelemetry: CompositeFenceTelemetry = CompositeFenceTelemetry()
    ) -> PresentedCompositeFrame? {
        guard frameSerial != 0 else { return nil }
        let key = Key(outputID: outputID, frameSerial: frameSerial)
        submissions[key] = nil
        frames[key] = nil
        guard let accepted = acceptedFrames.removeValue(forKey: key) else {
            discardedCompletions.insert(key)
            return nil
        }
        return PresentedCompositeFrame(
            frame: accepted.frame,
            atomicCommitAcceptedNs: accepted.atomicCommitAcceptedNs,
            pageflipNs: pageflipNs,
            fenceTelemetry: fenceTelemetry)
    }

    mutating func discard(outputID: UInt64, frameSerial: UInt64) {
        guard frameSerial != 0 else { return }
        let key = Key(outputID: outputID, frameSerial: frameSerial)
        submissions[key] = nil
        frames[key] = nil
        acceptedFrames[key] = nil
        discardedCompletions.insert(key)
    }

    private mutating func acceptIfComplete(_ key: Key) -> AcceptedCompositeFrame? {
        guard let submission = submissions[key], let frame = frames[key] else { return nil }
        submissions[key] = nil
        frames[key] = nil
        let accepted = AcceptedCompositeFrame(
            frame: frame, atomicCommitAcceptedNs: submission)
        acceptedFrames[key] = accepted
        return accepted
    }
}
