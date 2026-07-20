import NucleusCompositorDrmC
@_spi(NucleusPlatform) import NucleusRenderer
import Glibc

@MainActor
extension RendererRuntime {
    func allocatePresentationSubmissionID() -> UInt64 {
        let id = nextPresentationSubmissionID
        nextPresentationSubmissionID &+= 1
        if nextPresentationSubmissionID == 0 {
            nextPresentationSubmissionID = 1
        }
        return id
    }

    /// Complete only the submission carried by this exact output generation and
    /// kernel page-flip token. Stale generations cannot rotate or notify a
    /// replacement binding.
    func notePageFlipComplete(
        _ outputID: UInt64,
        _ generation: UInt64,
        _ event: DrmPageFlipEvent
    ) {
        guard let binding = bindings[outputID],
            binding.generation == generation
        else { return }
        let normalizedEvent = binding.presentationEvents.accept(
            event, clock: presentationClock)
        let submissionSerial = binding.pendingSubmissionSerial
        let presentationSubmissionID =
            binding.pendingPresentationSubmissionID
        binding.pendingSubmissionSerial = 0
        binding.pendingPresentationSubmissionID = 0
        var telemetry = submissionSerial != 0
            ? binding.pendingRenderSync?.takeFenceTelemetry()
                ?? CompositeFenceTelemetry()
            : CompositeFenceTelemetry()
        if submissionSerial != 0 {
            telemetry.gpuElapsedNs =
                core.takeCompletedSubmissionGpuElapsedNs(
                    submissionSerial)
            core.releaseRetiredGpuResources(
                completedSubmissionSerial: submissionSerial)
        }
        binding.pendingRenderSync = nil
        binding.drm.notePageFlipComplete()
        scanoutSurfaces.flipCompleted(output: outputID)

        guard let normalizedEvent else {
            logRendererDrm(
                "output \(outputID) generation \(generation): rejected page flip " +
                "timestamp=\(event.timestampNs) sequence=\(event.sequence)")
            onOutputPresentationDiscarded?(
                outputID,
                binding.generation,
                presentationSubmissionID,
                submissionSerial)
            return
        }
        onOutputPresented?(
            outputID,
            binding.generation,
            presentationSubmissionID,
            submissionSerial,
            normalizedEvent.timestampNs,
            normalizedEvent.sequence,
            telemetry)
    }

    public func handleDrmEvents() {
        _ = DrmEventPump.dispatchIfReady(fd: drmDeviceFd)
    }

    /// Drain a previously accepted nonblocking flip before topology retirement.
    /// The bounded polling interval prevents destruction of KMS-borrowed owners
    /// while allowing the caller to defer a transition that has not completed.
    func drainPendingFlip(
        _ binding: RenderOutputBinding
    ) -> Bool {
        for _ in 0..<10 where binding.drm.pageFlipPending {
            var descriptor = pollfd(
                fd: drmDeviceFd,
                events: Int16(POLLIN),
                revents: 0)
            if poll(&descriptor, 1, 10) > 0 {
                _ = DrmEventPump.dispatchIfReady(
                    fd: drmDeviceFd)
            }
        }
        return !binding.drm.pageFlipPending
    }
}
