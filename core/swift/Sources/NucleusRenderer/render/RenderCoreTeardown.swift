import NucleusSkiaGraphiteBridge
import VulkanC
import Vulkan
import Tracy
internal import NucleusRenderModel
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
    public func shutdownRenderResources() {
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
        clientUploadTextures.removeAll()
        retiredClientUploadTextures.removeAll()
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
        for retired in retiredSurfaceImages {
            retired.image.release()
            onSurfaceReleaseSync?(retired.releaseID)
        }
        retiredSurfaceImages.removeAll()
        outputTargets.removeAll()
        outputPresentationLedger.removeAll()
    }

    /// Release resources whose last possible queue use is no newer than a completed
    /// submission. A KMS page flip gated by submission N proves every earlier item
    /// on the single graphics queue has completed, independent of other outputs'
    /// flip phase.
    public func releaseRetiredGpuResources(completedSubmissionSerial: UInt64 = .max) {
        let graphiteCompletedSerial = pollCompletedSubmissionSerial()
        let safeSubmissionSerial = min(completedSubmissionSerial, graphiteCompletedSerial)
        var pendingImages: [(serial: UInt64, image: VkOwnedImageBox, releaseID: UInt64)] = []
        pendingImages.reserveCapacity(retiredSurfaceImages.count)
        for retired in retiredSurfaceImages {
            if retired.serial <= safeSubmissionSerial {
                retired.image.release()
                onSurfaceReleaseSync?(retired.releaseID)
            } else {
                pendingImages.append(retired)
            }
        }
        retiredSurfaceImages = pendingImages
        retiredClientUploadTextures.removeAll { $0.serial <= safeSubmissionSerial }
        retiredClientAcquireSemaphores.removeAll { $0.serial <= safeSubmissionSerial }
    }

    /// Poll Graphite's completion callbacks without blocking. Platform backends
    /// use the same serial authority to retire objects from submissions that never
    /// reached their normal presentation-completion path.
    @_spi(NucleusPlatform)
    public func pollCompletedSubmissionSerial() -> UInt64 {
        frameDriver?.pollCompletedSubmissionSerial() ?? .max
    }

    /// Consume the Graphite/Vulkan timestamp-query duration for one completed
    /// composite submission. The pageflip path calls this before releasing the
    /// synchronization objects retained by DRM.
    @_spi(NucleusPlatform)
    public func takeCompletedSubmissionGpuElapsedNs(_ submissionSerial: UInt64) -> UInt64? {
        frameDriver?.takeCompletedSubmissionGpuElapsedNs(submissionSerial)
    }

    /// Drain submitted GPU work before platform-owned synchronization and scanout
    /// objects are destroyed during shutdown or exceptional presentation recovery.
    public func waitForGpuIdle() {
        _ = deviceDispatch.vkQueueWaitIdle?(graphicsQueue)
    }

    /// Drop Graphite first, then the Vulkan device + instance — step two of
    /// teardown, run AFTER the backend tears down its images. Graphite borrows the
    /// Vulkan handles and must never survive `vkDestroyDevice`.
    public func teardownDevice() {
        context.reset()
        deviceBox = nil
        instanceLifetime = nil
    }
}
