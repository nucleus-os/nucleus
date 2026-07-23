import VulkanC
import Vulkan
import NucleusCompositorDrmC
import NucleusRenderModel
@_spi(NucleusPlatform) public import NucleusRenderer
import Tracy
import Glibc

@MainActor
extension RendererRuntime {
    /// Keep an explicit-sync semaphore alive when its submitted GPU work did not
    /// reach KMS. Completion serials replace exceptional queue-idle stalls on the
    /// compositor thread.
    private func retainUnpresentedRenderSync(
        _ sync: DrmRenderSync,
        submissionSerial: UInt64
    ) {
        precondition(submissionSerial != 0)
        sync.submissionSerial = submissionSerial
        sync.closeSyncFd()
        unpresentedRenderSyncs.append(sync)
        Trace.plot(
            "swift.renderer.unpresented_render_syncs",
            UInt64(unpresentedRenderSyncs.count))
    }

    func retireCompletedUnpresentedRenderSyncs() {
        guard !unpresentedRenderSyncs.isEmpty else { return }
        let completedSerial = core.pollCompletedSubmissionSerial()
        unpresentedRenderSyncs.removeAll {
            $0.submissionSerial <= completedSerial
        }
        core.releaseRetiredGpuResources(
            completedSubmissionSerial: completedSerial)
        Trace.plot(
            "swift.renderer.unpresented_render_syncs",
            UInt64(unpresentedRenderSyncs.count))
    }

    public func renderReadyOutputs(
        outputIDs: Set<UInt64>
    ) -> Bool {
        retireCompletedUnpresentedRenderSyncs()
        guard !outputIDs.isEmpty else { return false }
        scheduledOutputIDs = outputIDs
        defer { scheduledOutputIDs = nil }
        return core.renderReady(backend: self)
    }

    @_spi(NucleusPlatform)
    public func takeFrameTelemetry()
        -> [RenderFrameTelemetry]
    {
        core.takeFrameTelemetry()
    }

    public func setScanoutCandidates(
        _ perOutput: [UInt64: ScanoutCandidate]
    ) {
        scanoutCandidates = perOutput
        for (outputID, candidate) in perOutput {
            guard let formats =
                primaryPlaneFormats[outputID]
            else { continue }
            let eligibility = candidate.evaluate(
                primaryPlaneFormats: formats)
            let reason = eligibility.reason
            if lastScanoutDecision[outputID] != reason {
                lastScanoutDecision[outputID] = reason
                scanoutEligibilityChangeCount &+= 1
                Trace.plot(
                    "swift.renderer.scanout.eligibility_changes",
                    scanoutEligibilityChangeCount)
                Trace.plot(
                    "swift.renderer.scanout.eligible",
                    UInt64(eligibility.isEligible ? 1 : 0))
                logScanout(
                    "output \(outputID): direct-scanout \(reason)")
            }
        }
        lastScanoutDecision =
            lastScanoutDecision.filter {
                perOutput[$0.key] != nil
            }
    }

    func evaluateScanout(
        _ outputID: UInt64
    ) -> ScanoutEligibility? {
        guard let candidate = scanoutCandidates[outputID],
            let formats = primaryPlaneFormats[outputID]
        else { return nil }
        return candidate.evaluate(
            primaryPlaneFormats: formats)
    }

    public func setCursorImage(
        pixels: [UInt8],
        width: UInt32,
        height: UInt32,
        hotspotX: Int32,
        hotspotY: Int32
    ) {
        cursorPixels = pixels
        cursorImageWidth = width
        cursorImageHeight = height
        cursorHotspotX = hotspotX
        cursorHotspotY = hotspotY
        for binding in bindings.values {
            binding.cursorPlane?.upload(
                pixels: pixels,
                srcWidth: Int(width),
                srcHeight: Int(height))
            cursorPresentDirty.insert(binding.outputId)
        }
    }

    public func setCursorPosition(
        x: Double,
        y: Double
    ) {
        guard x != cursorX || y != cursorY else {
            return
        }
        cursorX = x
        cursorY = y
        for binding in bindings.values
        where binding.cursorPlane != nil {
            cursorPresentDirty.insert(binding.outputId)
        }
    }

    public func gammaRampSize(
        outputID: UInt64
    ) -> UInt32 {
        guard let binding = bindings[outputID],
            binding.drm.props.crtcGammaLut != 0
        else { return 0 }
        return binding.drm.props.crtcGammaLutSize
    }

    @discardableResult
    public func applyGamma(
        outputID: UInt64,
        red: [UInt16],
        green: [UInt16],
        blue: [UInt16]
    ) -> Bool {
        guard let binding = bindings[outputID] else {
            return false
        }
        let size = Int(
            gammaRampSize(outputID: outputID))
        guard size > 0,
            red.count == size,
            green.count == size,
            blue.count == size
        else { return false }
        binding.drm.gamma.stage(
            table: red + green + blue,
            rampSize: size)
        return true
    }

    public func clearGamma(outputID: UInt64) {
        bindings[outputID]?.drm.gamma.stage(
            table: nil, rampSize: 0)
    }

    public func wantsPresent(
        _ outputID: UInt64
    ) -> Bool {
        cursorPresentDirty.contains(outputID)
            || forcedPresentOutputIDs.contains(outputID)
    }

    public func forcePresent(outputID: UInt64) {
        forcedPresentOutputIDs.insert(outputID)
    }

    private func cursorCommitState(
        for binding: RenderOutputBinding
    ) -> CursorCommitState? {
        guard let plane = binding.cursorPlane,
            plane.frontFbId != 0
        else { return nil }
        let placement = plane.placement(
            outputRect: binding.logicalRect,
            fractionalScale: binding.fractionalScale,
            cursorX: cursorX,
            cursorY: cursorY,
            hotspotX: cursorHotspotX,
            hotspotY: cursorHotspotY)
        return CursorCommitState(
            fbId: plane.frontFbId,
            placement: placement)
    }

    public func setLockComposition(
        _ perOutput: [UInt64: Set<UInt32>]?
    ) {
        core.setLockComposition(perOutput.map { dictionary in
            dictionary.mapValues { values in
                Set(values.map { ContextID(raw: $0) })
            }
        })
    }

    public func presentableOutputIDs() -> [UInt64] {
        let ids = scheduledOutputIDs.map {
            Set(bindings.keys).intersection($0)
        } ?? Set(bindings.keys)
        return ids.sorted()
    }

    public func isReadyToPresent(
        _ outputID: UInt64
    ) -> Bool {
        retireCompletedUnpresentedRenderSyncs()
        guard backendState.admitsPresentation,
            let binding = bindings[outputID],
            binding.drm.lifecycleState.admitsScanoutCommit
        else { return false }
        return true
    }

    public func acquireTarget(
        _ outputID: UInt64
    ) -> AcquiredFrameTarget? {
        guard backendState.admitsPresentation,
            let binding = bindings[outputID],
            binding.drm.lifecycleState.admitsScanoutCommit
        else { return nil }
        guard let renderSync = DrmRenderSync(
                device: core.deviceHandle,
                dispatch: core.deviceDispatch)
        else {
            logScanout(
                "output \(outputID): failed to allocate required explicit render fence")
            return nil
        }
        let slot = binding.nextSlot()
        binding.currentSlot = slot
        binding.currentRenderSync = renderSync
        return AcquiredFrameTarget(
            image: slot.imageHandle,
            width: binding.width,
            height: binding.height,
            format: binding.format,
            tiling:
                VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: DmaBufImageDescriptor.scanoutUsage,
            queueFamily: binding.queueFamily,
            hasAlpha: false,
            kind: .drmScanout,
            signalSemaphore: renderSync.semaphore)
    }

    public func didSubmitTarget(
        _ outputID: UInt64
    ) -> Bool {
        guard let binding = bindings[outputID],
            let sync = binding.currentRenderSync
        else { return false }
        guard sync.exportSyncFd() else {
            logScanout(
                "output \(outputID): vkGetSemaphoreFdKHR failed")
            for surfaceID
                in core.lastFrameAcquiredSurfaceIDs
            {
                pendingClientAcquireFenceDiagnostics[
                    surfaceID] = nil
            }
            retainUnpresentedRenderSync(
                sync,
                submissionSerial: core.lastSubmittedSerial)
            binding.currentRenderSync = nil
            return false
        }
        sync.submissionSerial = core.lastSubmittedSerial
        sync.attachClientAcquireFenceDiagnostics(
            core.lastFrameAcquiredSurfaceIDs.compactMap {
                pendingClientAcquireFenceDiagnostics
                    .removeValue(forKey: $0)
            })
        return true
    }

    public func discardAcquiredTarget(
        _ outputID: UInt64
    ) {
        guard let binding = bindings[outputID] else {
            return
        }
        // A failed record never submitted the semaphore. Submitted failures in
        // finalize/present move it to `unpresentedRenderSyncs` before this cleanup.
        binding.currentRenderSync = nil
        binding.currentSlot = nil
    }

    public func present(_ outputID: UInt64) -> Bool {
        guard backendState.admitsPresentation,
            let binding = bindings[outputID],
            let slot = binding.currentSlot,
            let sync = binding.currentRenderSync,
            sync.syncFd >= 0
        else { return false }
        let cursor = cursorCommitState(for: binding)
        let needsModeset = !binding.drm.active
        var result = binding.drm.commitScanout(
            retaining: SubmittedCompositeScanout(
                slot: slot, sync: sync),
            fbId: slot.fbId,
            requestedVrr: false,
            modeset: needsModeset,
            inFenceFd: sync.syncFd,
            cursor: cursor)
        if result != 0, cursor != nil {
            result = binding.drm.commitScanout(
                retaining: SubmittedCompositeScanout(
                    slot: slot, sync: sync),
                fbId: slot.fbId,
                requestedVrr: false,
                modeset: needsModeset,
                inFenceFd: sync.syncFd,
                cursor: nil)
            if result == 0 {
                logScanout(
                    "output \(outputID): cursor-plane commit rejected; disabling hardware cursor")
                binding.cursorPlane?.destroy()
                binding.cursorPlane = nil
            }
        }
        if result == 0 {
            let acceptedNs = rendererMonotonicNowNs()
            let presentationSubmissionID =
                allocatePresentationSubmissionID()
            binding.pendingSubmissionSerial =
                sync.submissionSerial
            binding.pendingPresentationSubmissionID =
                presentationSubmissionID
            binding.pendingRenderSync = sync
            sync.closeSyncFd()
            binding.currentRenderSync = nil
            binding.currentSlot = nil
            scanoutSurfaces.submitComposite(
                output: outputID)
            cursorPresentDirty.remove(outputID)
            forcedPresentOutputIDs.remove(outputID)
            onOutputSubmitted?(
                outputID,
                binding.generation,
                presentationSubmissionID,
                sync.submissionSerial,
                acceptedNs,
                core.lastFrameAcquiredSurfaceIDs)
        } else {
            retainUnpresentedRenderSync(
                sync,
                submissionSerial: sync.submissionSerial)
            binding.currentRenderSync = nil
            binding.currentSlot = nil
            binding.pendingRenderSync = nil
            logScanout(
                "output \(outputID): atomic scanout commit failed rc=\(result) errno=\(rendererErrno()) modeset=\(needsModeset)")
        }
        return result == 0
    }

    public func didPresentFrame() {}

    public func tryDirectScanout(
        _ outputID: UInt64
    ) -> Bool {
        guard backendState.admitsPresentation,
            let binding = bindings[outputID],
            binding.drm.lifecycleState.admitsScanoutCommit,
            case .eligible(let iosurfaceID)? =
                evaluateScanout(outputID),
            iosurfaceID != 0,
            pendingSurfaceReleaseSync[iosurfaceID] != nil
        else { return false }
        let framebufferID = clientScanoutFramebuffer(
            iosurfaceID: iosurfaceID,
            validateWith: binding.drm)
        guard framebufferID != 0,
            let clientBuffer =
                clientScanoutBuffers[iosurfaceID]
        else { return false }

        let vrr = binding.drm.requestedVrr(
            directScanoutEligible: true)
        let acquireFenceFD =
            clientBuffer.takeAcquireFenceFd()
        defer {
            if acquireFenceFD >= 0 {
                close(acquireFenceFD)
            }
        }
        let result = binding.drm.commitScanout(
            retaining: clientBuffer,
            fbId: framebufferID,
            requestedVrr: vrr,
            modeset: false,
            inFenceFd: acquireFenceFD,
            cursor: cursorCommitState(for: binding))
        guard result == 0 else { return false }

        let acceptedNs = rendererMonotonicNowNs()
        let presentationSubmissionID =
            allocatePresentationSubmissionID()
        binding.pendingSubmissionSerial = 0
        binding.pendingPresentationSubmissionID =
            presentationSubmissionID
        binding.pendingRenderSync = nil
        pendingClientAcquireFenceDiagnostics[
            iosurfaceID] = nil
        core.discardPendingSurfaceAcquire(
            iosurfaceID: iosurfaceID)
        scanoutSurfaces.submitScanout(
            output: outputID,
            iosurfaceID: iosurfaceID)
        cursorPresentDirty.remove(outputID)
        forcedPresentOutputIDs.remove(outputID)
        onOutputSubmitted?(
            outputID,
            binding.generation,
            presentationSubmissionID,
            0,
            acceptedNs,
            [iosurfaceID])
        return true
    }
}
