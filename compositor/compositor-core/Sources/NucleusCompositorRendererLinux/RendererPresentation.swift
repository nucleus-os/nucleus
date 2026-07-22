import NucleusCompositorDrmC
@_spi(NucleusPlatform) import NucleusRenderer

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
        guard binding.drm.notePageFlipComplete() else {
            logRendererDrm(
                "output \(outputID) generation \(generation): ignored duplicate or late page flip")
            return
        }
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
        retireCompletedUnpresentedRenderSyncs()
        binding.pendingRenderSync = nil
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
        retireCompletedUnpresentedRenderSyncs()
    }
}
