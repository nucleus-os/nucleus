import NucleusSkiaGraphiteBridge
import VulkanC
import Vulkan
import Tracy
import NucleusRenderModel
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
@MainActor
extension RenderCore {
    public func recordFrame(outputID: UInt64, target: AcquiredFrameTarget) -> Bool {
        let renderStarted = telemetryClock.now
        lastFrameRenderStarted = renderStarted
        lastFrameAcquiredSurfaceIDs.removeAll(keepingCapacity: true)
        guard let driver = frameDriver, let renderTarget = outputTargets[outputID] else { return false }
        for handle in resourceHost.images.takeEvictedHandles() {
            driver.evictDecodedImage(handle)
        }
        for handle in resourceHost.runtimeEffects.takeEvictedHandles() {
            driver.evictCompiledEffect(handle)
        }
        frameSerial &+= 1
        let frame = FrameInfo(
            outputId: outputID, width: UInt32(target.width), height: UInt32(target.height),
            scale: renderTarget.scale, frameSerial: frameSerial,
            fullDamage: outputsNeedingInitialFrame.contains(outputID))

        // Wrap a TRANSIENT surface over the borrowed image, render into it, and let
        // it drop at the end of this scope. No long-lived surface outlives the image.
        var phaseStarted = telemetryClock.now
        let params = ScanoutImageParams(
            image: target.image, memory: nil, allocSize: 0,
            width: target.width, height: target.height, format: target.format,
            tiling: target.tiling, initialLayout: target.initialLayout,
            usageFlags: target.usageFlags, queueFamilyIndex: target.queueFamily,
            hasAlpha: target.hasAlpha)
        let surface = ScanoutSurface.wrap(recorder: driver.recorder, params: params)
        guard surface.isValid() else { return false }
        let targetWrapNs = elapsedNanoseconds(phaseStarted, telemetryClock.now)

        // Select the platform completion contract before recording. A DRM target
        // without its required exportable signal semaphore is invalid; it must
        // never degrade into an ordinary or CPU-synchronous submit.
        let submissionMode: FrameDriver.SubmissionMode
        switch target.kind {
        case .swapchainColor:
            submissionMode = .swapchain(FrameDriver.PresentSubmit(
                waitSemaphore: target.waitSemaphore,
                signalSemaphore: target.signalSemaphore,
                queueFamily: target.queueFamily))
        case .drmScanout:
            guard let signalSemaphore = target.signalSemaphore else { return false }
            submissionMode = .drm(FrameDriver.DrmSubmit(
                signalSemaphore: signalSemaphore))
        }

        phaseStarted = telemetryClock.now
        let tree = store.snapshot()
        let treeSnapshotNs = elapsedNanoseconds(phaseStarted, telemetryClock.now)
        // Session-lock choke point: while locked, restrict this output's composition
        // to its allowed lock-surface contexts (empty/absent → fully blanked). nil is
        // the normal, unrestricted composition.
        let lockContexts: Set<ContextID>? = lockComposition.map { $0[outputID] ?? [] }
        let rootContexts = outputRootContexts[outputID] ?? [compositorContextId]
        let result = driver.renderFrame(
            tree: tree, target: renderTarget, frame: frame, scanout: surface,
            submissionMode: submissionMode,
            acquireWaitSemaphore: { surfaceID in
                pendingClientAcquireSemaphores[surfaceID]?.semaphore
            },
            rootContexts: rootContexts,
            lockContexts: lockContexts,
            resolvePaintContent: { resourceHost.paintContents.content($0) },
            resolvePaintImage: { handle in
                guard let source = resourceHost.images.source(handle) else { return nil }
                return driver.decodedImage(handle: handle, source: source)
            }
        ) { [snapshots] handle in
            if let entry = snapshots.resolve(SnapshotHandle(raw: handle.raw)) {
                return driver.registry.resolve(entry.texture.raw)
            }
            return driver.registry.resolve(handle.raw)
        }
        guard let result else { return false }
        lastFrameAcquiredSurfaceIDs = result.acquiredSurfaceIDs
        var telemetry = RenderFrameTelemetry()
        telemetry.generation = lastFrameTelemetry.generation &+ 1
        telemetry.outputID = outputID
        telemetry.frameSerial = frameSerial
        telemetry.operationCount = UInt64(result.opsDrawn + result.backdropDraws)
        telemetry.referencedSurfaceCount = UInt64(result.referencedSurfaceIDs.count)
        let changed = result.referencedSurfaceIDs.compactMap { clientCommitInstants[$0] }
        telemetry.changedSurfaceCount = UInt64(changed.count)
        telemetry.damageRectCount = UInt64(result.damageRectCount)
        telemetry.damagePixelCount = result.damagePixelCount
        telemetry.fullDamage = result.fullDamage
        let producerStats = driver.takeProducerWorkStats()
        telemetry.paintRepaintCount = producerStats.paintRepaint
        telemetry.partialPaintRepaintCount = producerStats.paintPartialRepaint
        telemetry.fullPaintRepaintCount = producerStats.paintFullRepaint
        telemetry.shadowRepaintCount = producerStats.shadowRepaint
        telemetry.producerDrawCount = producerStats.drawQuad
        telemetry.producerTexturePassCount = producerStats.texturePass
        telemetry.producerInvalidationCount = producerStats.invalidate
        Trace.plot(
            "swift.nucleus.renderer.paint_repaints",
            producerStats.paintRepaint)
        Trace.plot(
            "swift.nucleus.renderer.paint_partial_repaints",
            producerStats.paintPartialRepaint)
        Trace.plot(
            "swift.nucleus.renderer.paint_full_repaints",
            producerStats.paintFullRepaint)
        Trace.plot(
            "swift.nucleus.renderer.shadow_repaints",
            producerStats.shadowRepaint)
        Trace.plot(
            "swift.nucleus.renderer.producer_draws",
            producerStats.drawQuad)
        Trace.plot(
            "swift.nucleus.renderer.texture_passes",
            producerStats.texturePass)
        Trace.plot(
            "swift.nucleus.renderer.producer_invalidations",
            producerStats.invalidate)
        Trace.plot(
            "swift.nucleus.renderer.damage_regions",
            telemetry.damageRectCount)
        Trace.plot(
            "swift.nucleus.renderer.damage_pixels",
            telemetry.damagePixelCount)
        telemetry.clientCommitToRenderNs = changed.map {
            elapsedNanoseconds($0, renderStarted)
        }
        telemetry.oldestCommitToRenderNs = telemetry.clientCommitToRenderNs.max() ?? 0
        telemetry.targetWrapNs = targetWrapNs
        telemetry.treeSnapshotNs = treeSnapshotNs
        telemetry.timings = result.timings
        lastFrameTelemetry = telemetry
        lastFrameReferencedCommitInstants = result.referencedSurfaceIDs.reduce(into: [:]) {
            if let instant = clientCommitInstants[$1] { $0[$1] = instant }
        }
        if startupFrameDiagnosticsRemaining > 0 {
            startupFrameDiagnosticsRemaining -= 1
            let line = "render-frame: output=\(outputID) serial=\(frameSerial) layers=\(tree.layers.count) ops=\(result.opsDrawn) backdrops=\(result.backdropDraws) damage=\(result.damageRectCount) full_damage=\(result.fullDamage) acquire_waits=\(result.acquireWaitCount) presented=\(result.presented) submitted=\(result.submitted) uploads=\(clientUploadStats.uploaded) upload_failures=\(clientUploadStats.failed)\n"
            line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
        }
        guard result.presented, result.submitted else { return false }
        lastSubmittedSerial = frameSerial
        for id in result.acquiredSurfaceIDs {
            if let semaphore = pendingClientAcquireSemaphores.removeValue(forKey: id) {
                retiredClientAcquireSemaphores.append((frameSerial, semaphore))
            }
        }
        return true
    }

    /// Drain telemetry produced by actual frame records since the previous call.
    /// A queue, rather than a "last frame" slot, preserves every output in a
    /// multi-output render pass and prevents idle reactor turns from republishing
    /// stale timings.
    @_spi(NucleusPlatform)
    public func takeFrameTelemetry() -> [RenderFrameTelemetry] {
        let events = pendingFrameTelemetry
        pendingFrameTelemetry.removeAll(keepingCapacity: true)
        return events
    }

    /// Drive a render pass over `backend`: for each presentable output that is
    /// ready and has pending damage, acquire the image to record into, record the
    /// retained tree, and present. Returns true if any output presented this pass.
    @discardableResult
    public func renderReady(backend: PresentationBackend) -> Bool {
        guard frameDriver != nil else { return false }
        // Client request dispatch only copies/converts SHM. Materialize the latest
        // generation per surface only when some output can consume a frame; while a
        // page flip is pending the queue continues coalescing instead of growing
        // unsnapped transfer work on the upload recorder.
        let outputIDs = backend.presentableOutputIDs()
        let targetRevision = store.revision
        let targetLockGeneration = lockCompositionGeneration
        let targetResourceGeneration =
            frameDriver?.imageDecodeCompletionGeneration ?? 0
        if outputIDs.contains(where: { backend.isReadyToPresent($0) }) {
            drainPendingShmUploads()
        }
        // Force a redraw across outputs while locked (keep the blank present) and on
        // the frame a lock begins/ends (the composition-time filter is not tree
        // damage). Otherwise the damage gate decides per output as normal.
        // Locked outputs redraw continuously. The transition into or out of lock is
        // acknowledged independently by every output, so a flip-pending output can
        // never miss the one-shot composition filter change.
        // Captured before the loop: `markPresented` clears damage per output. A
        // structural change (layer removal) always damages the tree, so this gates
        // producer-cache GC to passes where a layer may have gone away.
        let hadDamage = store.hasPendingDamage
        var any = false
        for outputID in outputIDs {
            if !backend.isReadyToPresent(outputID) { continue }
            let hasPendingDamage = outputPresentationLedger.needsTreeRevision(
                targetRevision, outputID: outputID)
            let forced = lockComposition != nil
                || outputPresentationLedger.needsLockGeneration(
                    targetLockGeneration, outputID: outputID)
                || outputPresentationLedger.needsResourceGeneration(
                    targetResourceGeneration, outputID: outputID)
            guard Self.shouldRenderOutput(
                hasPendingDamage: hasPendingDamage,
                forced: forced,
                wantsPresent: backend.wantsPresent(outputID),
                needsInitialFrame: outputsNeedingInitialFrame.contains(outputID)
            ) else { continue }
            // Direct scanout: if a fullscreen client buffer can go straight onto the
            // primary plane, present it with no composition and skip the record pass.
            // Any miss falls through to compositing this output normally.
            if backend.tryDirectScanout(outputID) {
                outputPresentationLedger.acknowledge(
                    outputID, treeRevision: targetRevision,
                    lockGeneration: targetLockGeneration,
                    resourceGeneration: targetResourceGeneration)
                outputsNeedingInitialFrame.remove(outputID)
                any = true
                continue
            }
            let acquireStarted = telemetryClock.now
            guard let target = backend.acquireTarget(outputID) else { continue }
            outputAcquisitionCount &+= 1
            Trace.plot(
                "swift.nucleus.renderer.output_acquisitions",
                outputAcquisitionCount)
            let acquireTargetNs = elapsedNanoseconds(acquireStarted, telemetryClock.now)
            let recordStarted = telemetryClock.now
            guard recordFrame(outputID: outputID, target: target) else {
                // The acquire succeeded but the frame could not be recorded. Let the
                // backend undo the acquire (WSI: consume the acquire semaphore +
                // return the image via a blank present), so the next acquire does not
                // wait on a still-signaled semaphore and eventually deadlock.
                backend.discardAcquiredTarget(outputID)
                continue
            }
            lastFrameTelemetry.acquireTargetNs = acquireTargetNs
            lastFrameTelemetry.recordNs = elapsedNanoseconds(recordStarted, telemetryClock.now)
            let finalizeStarted = telemetryClock.now
            let finalized = backend.didSubmitTarget(outputID)
            lastFrameTelemetry.backendFinalizeNs = elapsedNanoseconds(
                finalizeStarted, telemetryClock.now)
            guard finalized else {
                frameDriver?.discardSubmittedSnapshot(output: outputID)
                backend.discardAcquiredTarget(outputID)
                continue
            }
            let presentStarted = telemetryClock.now
            let accepted = backend.present(outputID)
            lastFrameTelemetry.backendPresentNs = elapsedNanoseconds(
                presentStarted, telemetryClock.now)
            if accepted {
                frameDriver?.commitSubmittedSnapshot(output: outputID)
                if let renderStarted = lastFrameRenderStarted {
                    lastFrameTelemetry.recordToSubmitNs = elapsedNanoseconds(
                        renderStarted, telemetryClock.now)
                }
                pendingFrameTelemetry.append(lastFrameTelemetry)
                outputPresentationLedger.acknowledge(
                    outputID, treeRevision: targetRevision,
                    lockGeneration: targetLockGeneration,
                    resourceGeneration: targetResourceGeneration)
                outputsNeedingInitialFrame.remove(outputID)
                presentedCommitsAwaitingRevisionAck.merge(
                    lastFrameReferencedCommitInstants, uniquingKeysWith: { _, newest in newest })
                any = true
            } else {
                frameDriver?.discardSubmittedSnapshot(output: outputID)
            }
        }
        if any {
            backend.didPresentFrame()
            // Clear the shared tree flags only after every attached output has
            // accepted this exact revision. Per-output revisions remain the render
            // authority; the shared flag is producer bookkeeping and diagnostics.
            if outputPresentationLedger.allPresented(outputIDs, treeRevision: targetRevision) {
                store.markPresented()
                for (id, presentedInstant) in presentedCommitsAwaitingRevisionAck
                where clientCommitInstants[id] == presentedInstant {
                    clientCommitInstants[id] = nil
                }
                presentedCommitsAwaitingRevisionAck.removeAll(keepingCapacity: true)
            }
        }
        if !backend.defersGpuResourceRetirement { releaseRetiredGpuResources() }
        // Reclaim producer cache textures for layers removed from the tree this pass.
        // Gated on pre-loop damage (a no-op when nothing was removed); uses the full
        // tree's live-layer set so it never evicts a layer that belongs to another
        // output not rendered this pass.
        if hadDamage, let driver = frameDriver {
            driver.collectProducerGarbage(liveLayerIds: store.liveLayerIDs)
        }
        return any
    }

}
