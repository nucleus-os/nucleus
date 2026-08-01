internal import NucleusRenderModel
import NucleusSkiaGraphiteBridge
import Tracy
import Vulkan
import VulkanC

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
@MainActor
extension RenderCore {
    // MARK: - Teardown

    /// Drop the render resources (snapshots, frame driver accumulators + registry
    /// images, imported client-surface images) — step one of GPU-lifetime teardown,
    /// run BEFORE the backend tears down its own scanout/swapchain images.
    package func shutdownRenderResources() {
        pendingPixelCaptureJobs.removeAll()
        pixelCaptureJobByKey.removeAll()
        pixelCaptureJobByRequest.removeAll()
        pendingPixelCaptureBytes = 0
        for pending in pendingDmabufCaptures.values {
            pending.releaseBacking()
        }
        pendingDmabufCaptures.removeAll()
        captureWorkStalled = false
        snapshots.releaseAll { _ in }
        Trace.plot("swift.nucleus.renderer.live_snapshots", UInt64(0))
        frameDriver?.shutdown()
        pendingShmUploads.removeAll()
        stagedShmUploads.removeAll()
        unsafe clientUploadTextures.removeAll()
        unsafe retiredClientUploadTextures.removeAll()
        pendingClientAcquireSemaphores.removeAll()
        retiredClientAcquireSemaphores.removeAll()
        clientUploadStats.pendingBytes = 0
        clientCommitInstants.removeAll()
        presentedCommitsAwaitingRevisionAck.removeAll()
        pendingFrameTelemetry.removeAll()
        lastFrameAcquiredSurfaceIDs.removeAll()
        outputAcquisitionCount = 0
        frameDriver = nil
        for box in importedSurfaceImages.values { box.release() }
        importedSurfaceImages.removeAll()
        for index in retiredSurfaceImages.indices {
            onSurfaceReleaseSync?(retiredSurfaceImages[index].releaseID)
        }
        retiredSurfaceImages.removeAll()
        outputTargets.removeAll()
        outputPresentationLedger.removeAll()
    }

    /// Release resources whose last possible queue use is no newer than a completed
    /// submission. Client mutation, recording, and submission are MainActor
    /// serialized, so replacement retires against `lastSubmittedSerial`: using a
    /// future serial would leak when no later frame is submitted. A KMS page flip
    /// gated by submission N proves every earlier item on the single graphics queue
    /// has completed, independent of other outputs' flip phase.
    package func releaseRetiredGpuResources(completedSubmissionSerial: UInt64 = .max) {
        let graphiteCompletedSerial = pollCompletedSubmissionSerial()
        let safeSubmissionSerial = min(completedSubmissionSerial, graphiteCompletedSerial)
        // A noncopyable element cannot be filtered in place, so drain from the back
        // — consuming a completed entry runs `VkOwned.deinit` and destroys the image
        // exactly once — then restore the original ascending-serial order for the
        // entries that carry forward. Release notifications fire after the drain, in
        // that same ascending order, so a callback can no longer re-enter this list
        // while it is being partitioned.
        var carried = UniqueArray<RetiredSurfaceImage>()
        carried.reserveCapacity(retiredSurfaceImages.count)
        var releasedIDs: [UInt64] = []
        while !retiredSurfaceImages.isEmpty {
            let retired = retiredSurfaceImages.removeLast()
            if ClientResourceRetirement(
                submissionSerial: retired.serial
            ).isComplete(completedSubmissionSerial: safeSubmissionSerial) {
                releasedIDs.append(retired.releaseID)
                _ = consume retired
            } else {
                carried.append(retired)
            }
        }
        while !carried.isEmpty {
            retiredSurfaceImages.append(carried.removeLast())
        }
        for releaseID in releasedIDs.reversed() {
            onSurfaceReleaseSync?(releaseID)
        }
        unsafe retiredClientUploadTextures.removeAll {
            unsafe ClientResourceRetirement(
                submissionSerial: $0.serial
            ).isComplete(completedSubmissionSerial: safeSubmissionSerial)
        }
        retiredClientAcquireSemaphores.removeAll {
            ClientResourceRetirement(
                submissionSerial: $0.serial
            ).isComplete(completedSubmissionSerial: safeSubmissionSerial)
        }
    }

    /// Poll Graphite's completion callbacks without blocking. Platform backends
    /// use the same serial authority to retire objects from submissions that never
    /// reached their normal presentation-completion path.
    package func pollCompletedSubmissionSerial() -> UInt64 {
        frameDriver?.pollCompletedSubmissionSerial() ?? .max
    }

    /// Consume the Graphite/Vulkan timestamp-query duration for one completed
    /// composite submission. The pageflip path calls this before releasing the
    /// synchronization objects retained by DRM.
    package func takeCompletedSubmissionGpuElapsedNs(_ submissionSerial: UInt64) -> UInt64? {
        frameDriver?.takeCompletedSubmissionGpuElapsedNs(submissionSerial)
    }

    /// Drain submitted GPU work before platform-owned synchronization and scanout
    /// objects are destroyed during shutdown or exceptional presentation recovery.
    package func waitForGpuIdle() {
        _ = unsafe deviceDispatch.vkQueueWaitIdle?(graphicsQueue)
    }

    /// Drop Graphite first, then the Vulkan device + instance — step two of
    /// teardown, run AFTER the backend tears down its images. Graphite borrows the
    /// Vulkan handles and must never survive `vkDestroyDevice`.
    package func teardownDevice() {
        unsafe context.reset()
        deviceBox = nil
        instanceLifetime = nil
    }
}
