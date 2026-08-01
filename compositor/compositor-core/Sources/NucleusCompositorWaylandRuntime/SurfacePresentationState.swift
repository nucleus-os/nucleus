import WaylandProtocolTypes
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

/// Exact commit-owned frame callback and presentation-feedback state.
@MainActor
@safe final class SurfacePresentationState {
    private struct PresentedSample {
        var outputs: [WlOutput]
        var timestampNs: UInt64
        var timeMs: UInt32
        var tvSecHi: UInt32
        var tvSecLo: UInt32
        var tvNsec: UInt32
        var refreshNs: UInt32
        var seqHi: UInt32
        var seqLo: UInt32
        var flags: UInt32
    }

    private struct CommitResources {
        var frameCallbacks: [WaylandResourceReference<WlCallbackServer>]
        var feedbacks: [WaylandResourceReference<WpPresentationFeedbackServer>]
        var sampledSubmissionIDs: Set<UInt64> = []
        var presented: PresentedSample?
    }

    private var commits: [UInt64: CommitResources] = [:]
    private(set) var currentCommitID: UInt64 = 0
    private(set) var completedFrameCallbacks = 0

    func install(
        commitID: UInt64,
        frameCallbacks: [WaylandResourceReference<WlCallbackServer>],
        feedbacks:
            [WaylandResourceReference<WpPresentationFeedbackServer>]
    ) {
        var callbacks = frameCallbacks
        if currentCommitID != 0,
            var superseded = commits[currentCommitID],
            superseded.sampledSubmissionIDs.isEmpty
        {
            callbacks = superseded.frameCallbacks + callbacks
            for feedback in superseded.feedbacks {
                feedback.handle.sendDiscarded()
                feedback.destroy()
            }
            superseded.frameCallbacks.removeAll()
            superseded.feedbacks.removeAll()
            commits[currentCommitID] = nil
        }
        currentCommitID = commitID
        commits[commitID] = CommitResources(
            frameCallbacks: callbacks, feedbacks: feedbacks)
    }

    func noteSampled(submissionID: UInt64) -> UInt64? {
        guard currentCommitID != 0,
            var resources = commits[currentCommitID]
        else { return nil }
        resources.sampledSubmissionIDs.insert(submissionID)
        commits[currentCommitID] = resources
        return currentCommitID
    }

    func complete(
        commitID: UInt64,
        submissionID: UInt64,
        output: WlOutput?,
        timeMs: UInt32,
        tvSecHi: UInt32,
        tvSecLo: UInt32,
        tvNsec: UInt32,
        refreshNs: UInt32,
        seqHi: UInt32,
        seqLo: UInt32,
        flags: UInt32
    ) {
        guard var resources = commits[commitID],
            resources.sampledSubmissionIDs.remove(submissionID) != nil
        else { return }
        let timestampNs =
            (UInt64(tvSecHi) << 32 | UInt64(tvSecLo))
            &* 1_000_000_000
            &+ UInt64(tvNsec)
        for callback in resources.frameCallbacks {
            guard callback.handle.sendDone(callback_data: timeMs) else {
                continue
            }
            callback.destroy()
            completedFrameCallbacks += 1
        }
        resources.frameCallbacks.removeAll()
        if var presented = resources.presented {
            if let output,
                !presented.outputs.contains(where: {
                    $0.outputId == output.outputId
                })
            {
                presented.outputs.append(output)
            }
            if timestampNs < presented.timestampNs {
                presented.timestampNs = timestampNs
                presented.timeMs = timeMs
                presented.tvSecHi = tvSecHi
                presented.tvSecLo = tvSecLo
                presented.tvNsec = tvNsec
                presented.refreshNs = refreshNs
                presented.seqHi = seqHi
                presented.seqLo = seqLo
                presented.flags = flags
            }
            resources.presented = presented
        } else {
            resources.presented = PresentedSample(
                outputs: output.map { [$0] } ?? [],
                timestampNs: timestampNs,
                timeMs: timeMs,
                tvSecHi: tvSecHi,
                tvSecLo: tvSecLo,
                tvNsec: tvNsec,
                refreshNs: refreshNs,
                seqHi: seqHi,
                seqLo: seqLo,
                flags: flags)
        }
        settleFeedbackIfReady(&resources)
        storeOrRemove(resources, commitID: commitID)
    }

    func discard(commitID: UInt64, submissionID: UInt64) {
        guard var resources = commits[commitID],
            resources.sampledSubmissionIDs.remove(submissionID) != nil
        else { return }
        settleFeedbackIfReady(&resources)
        if commitID != currentCommitID,
            !resources.frameCallbacks.isEmpty,
            var current = commits[currentCommitID]
        {
            current.frameCallbacks =
                resources.frameCallbacks + current.frameCallbacks
            resources.frameCallbacks.removeAll()
            commits[currentCommitID] = current
        }
        storeOrRemove(resources, commitID: commitID)
    }

    func destroyAll() {
        for resources in commits.values {
            for callback in resources.frameCallbacks {
                callback.destroy()
            }
            for feedback in resources.feedbacks {
                feedback.handle.sendDiscarded()
                feedback.destroy()
            }
        }
        commits.removeAll()
    }

    private func storeOrRemove(
        _ resources: CommitResources,
        commitID: UInt64
    ) {
        if resources.frameCallbacks.isEmpty,
            resources.feedbacks.isEmpty,
            resources.sampledSubmissionIDs.isEmpty,
            resources.presented == nil
        {
            commits[commitID] = nil
        } else {
            commits[commitID] = resources
        }
    }

    private func settleFeedbackIfReady(
        _ resources: inout CommitResources
    ) {
        guard resources.sampledSubmissionIDs.isEmpty else { return }
        if let presented = resources.presented {
            for feedback in resources.feedbacks {
                guard feedback.isLive else { continue }
                let feedbackHandle = feedback.handle
                let client = feedbackHandle.clientID
                for output in presented.outputs {
                    for outputResource in output.resources(
                        forClient: client)
                    {
                        feedbackHandle.sendSyncOutput(output: outputResource)
                    }
                }
                feedbackHandle.sendPresented(
                    tv_sec_hi: presented.tvSecHi,
                    tv_sec_lo: presented.tvSecLo,
                    tv_nsec: presented.tvNsec,
                    refresh: presented.refreshNs,
                    seq_hi: presented.seqHi,
                    seq_lo: presented.seqLo,
                    flags: WpPresentationFeedbackKind(
                        rawValue: presented.flags))
                feedback.destroy()
            }
        } else {
            for feedback in resources.feedbacks {
                feedback.handle.sendDiscarded()
                feedback.destroy()
            }
        }
        resources.feedbacks.removeAll()
        resources.presented = nil
    }
}
