// The process-global render-runtime owner: brings up the Swift render path over a
// DRM master fd, drives per-frame rendering, and routes client-buffer uploads,
// DRM events, and session pause/resume into the shared retained tree.
//
// The Swift-authoritative DRM primary-node session (`DrmSession`) was cleaved out
// of this file into the compositor package's `NucleusCompositorRenderSession`
// target: it references no renderer, so it is the dependency-clean half. This
// remainder stays renderer-coupled (it imports the cxx-interop `NucleusRenderer`
// graph) and relocates to the compositor package alongside that cluster.
//
// The owner and its entire API are main-actor-isolated: the render path runs on
// the compositor's single main-loop thread alongside the commit sink and tree.

import Glibc
@_spi(NucleusPlatform) import NucleusRenderer
@_spi(NucleusPlatform) import NucleusCompositorRendererLinux
import NucleusRenderModel
import NucleusRenderHost
import NucleusCompositorServer
import Tracy
@_spi(NucleusCompositor) import NucleusLayers

@MainActor
public enum RenderRuntime {
    public struct OutputInfo: Sendable, Equatable {
        public let topologyGeneration: UInt64
        public let id: UInt64
        public let pixelWidth: UInt32
        public let pixelHeight: UInt32
        public let refreshMhz: Int32
        public let physicalWidthMM: Int32
        public let physicalHeightMM: Int32
        public let crtcID: UInt32
        public let primaryPlaneID: UInt32
        public let cursorPlaneID: UInt32
    }
    public struct OutputTopologyProposal: Sendable, Equatable {
        public let generation: UInt64
        public let outputs: [OutputInfo]
    }
    /// The process-global renderer-owner, constructed by `bringUp`.
    private static var shared: RendererRuntime?
    private static weak var retainedStore: RetainedTreeStore?
    private static var telemetryCorrelator = PresentationTelemetryCorrelator()

    private static func monotonicNowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    /// Bring up the Swift render runtime over the DRM master fd and install the
    /// Swift-direct commit sink (transactions fold into the shared retained tree).
    /// Returns false when the GPU/GBM stack is unavailable. Idempotent.
    public static func bringUp(
        drmDeviceFd: Int32,
        dmabufMainDevice: UInt64,
        store: RetainedTreeStore,
        resourceHost: SwiftResourceHost,
        asyncRenderWakeSink: any AsyncRenderWakeSink
    ) -> Bool {
        if let shared {
            NucleusCompositorServer.shared.renderService = shared
            return true
        }
        guard let runtime = RendererRuntime.create(
                drmDeviceFd: drmDeviceFd,
                store: store,
                resourceHost: resourceHost,
                asyncRenderWakeSink: asyncRenderWakeSink)
        else { return false }
        telemetryCorrelator = PresentationTelemetryCorrelator()
        runtime.dmabufMainDevice = dmabufMainDevice
        shared = runtime
        retainedStore = store
        NucleusCompositorServer.shared.renderService = runtime
        return true
    }

    /// Discover and globally allocate every connected DRM output without changing
    /// live KMS bindings. The composition root applies the returned proposal.
    public static func proposeOutputTopology() -> OutputTopologyProposal? {
        guard let proposal = shared?.proposeConnectedOutputTopology() else {
            return nil
        }
        return OutputTopologyProposal(
            generation: proposal.generation,
            outputs: proposal.outputs.map {
                OutputInfo(
                topologyGeneration: $0.topologyGeneration,
                id: $0.id, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                refreshMhz: $0.refreshMhz, physicalWidthMM: $0.physicalWidthMM,
                physicalHeightMM: $0.physicalHeightMM,
                crtcID: $0.crtcID, primaryPlaneID: $0.primaryPlaneID,
                cursorPlaneID: $0.cursorPlaneID)
            })
    }

    /// Apply one member of the current topology proposal.
    public static func applyProposedOutput(
        _ output: OutputInfo,
        logicalX: Double, logicalY: Double,
        logicalWidth: Double, logicalHeight: Double,
        fractionalScale: Double
    ) -> Bool {
        shared?.applyProposedOutput(
            RendererOutputInfo(
                topologyGeneration: output.topologyGeneration,
                id: output.id,
                pixelWidth: output.pixelWidth,
                pixelHeight: output.pixelHeight,
                refreshMhz: output.refreshMhz,
                physicalWidthMM: output.physicalWidthMM,
                physicalHeightMM: output.physicalHeightMM,
                crtcID: output.crtcID,
                primaryPlaneID: output.primaryPlaneID,
                cursorPlaneID: output.cursorPlaneID),
            logicalX: logicalX, logicalY: logicalY,
            logicalWidth: logicalWidth, logicalHeight: logicalHeight,
            fractionalScale: fractionalScale) ?? false
    }

    @discardableResult
    public static func retireOutput(
        _ outputID: UInt64
    ) -> RendererRetirementResult {
        shared?.retireOutput(outputID) ?? .complete
    }

    @discardableResult
    public static func retireOutputs(
        _ outputIDs: Set<UInt64>
    ) -> RendererRetirementResult {
        shared?.retireOutputs(outputIDs) ?? .complete
    }

    public static func commitProposedTopology(
        generation: UInt64, appliedOutputIDs: Set<UInt64>
    ) {
        shared?.commitProposedTopology(
            generation: generation, appliedOutputIDs: appliedOutputIDs)
    }

    /// Drain pending DRM events (page-flip completions) on the master fd. Called
    /// from the reactor's DRM-readiness handler.
    public static func handleDrmEvents() {
        shared?.handleDrmEvents()
    }

    /// Suspend the render session on VT-switch-away (drop DRM master + cancel
    /// pending flips).
    @discardableResult
    public static func pauseSession() -> RendererRetirementResult {
        shared?.pauseSessionChecked() ?? .complete
    }

    /// Resume the render session on VT-switch-back (reacquire DRM master).
    @discardableResult
    public static func resumeSession() -> Bool {
        shared?.resumeSessionChecked() ?? false
    }

    public static func prepareShutdown() -> RendererRetirementResult {
        shared?.prepareShutdown() ?? .complete
    }

    /// Advance animations to the current present time, then render + flip every
    /// output with pending damage. Returns true if any output flipped this vblank.
    public static func renderOutputs(_ outputIDs: Set<UInt64>) -> Bool {
        guard !outputIDs.isEmpty else { return false }
        let presentNs = monotonicNowNs()
        guard let runtime = shared else { return false }
        _ = Trace.zone("renderer.store_tick", color: Trace.Color.blue) {
            runtime.store.tick(presentTimeNs: presentNs)
        }
        return Trace.zone("renderer.client_upload_and_frame", color: Trace.Color.green) {
            let rendered = runtime.renderReadyOutputs(outputIDs: outputIDs)
            for frame in runtime.takeFrameTelemetry() {
                if let accepted = telemetryCorrelator.noteFrame(frame) {
                    publishAcceptedFrame(accepted, uploadStats: runtime.clientUploadStats)
                }
            }
            return rendered
        }
    }

    private static func plotMilliseconds(_ name: String, _ nanoseconds: UInt64) {
        Trace.plot(name, Double(nanoseconds) / 1_000_000.0)
    }

    private static func plotSignedIntervalMilliseconds(
        _ name: String, from startNs: UInt64, to endNs: UInt64
    ) {
        let value = endNs >= startNs
            ? Double(endNs - startNs) / 1_000_000.0
            : -Double(startNs - endNs) / 1_000_000.0
        Trace.plot(name, value)
    }

    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? UInt64.max : sum
        }
    }

    private static func saturatingResidual(total: UInt64, phases: [UInt64]) -> UInt64 {
        let measured = saturatingSum(phases)
        return total >= measured ? total - measured : 0
    }

    private static func publishAcceptedFrame(
        _ accepted: AcceptedCompositeFrame, uploadStats: RenderCore.ClientUploadStats
    ) {
        let frame = accepted.frame
        let timing = frame.timings
        Trace.plot("swift.renderer.frame.output_id", frame.outputID)
        Trace.plot("swift.renderer.frame.serial", frame.frameSerial)
        plotMilliseconds("swift.renderer.frame.acquire_target_ms", frame.acquireTargetNs)
        plotMilliseconds("swift.renderer.frame.target_wrap_ms", frame.targetWrapNs)
        plotMilliseconds("swift.renderer.frame.tree_snapshot_ms", frame.treeSnapshotNs)
        plotMilliseconds("swift.renderer.frame.plan_ms", timing.planNs)
        plotMilliseconds("swift.renderer.frame.resolve_ms", timing.resolveNs)
        plotMilliseconds("swift.renderer.frame.accumulator_ms", timing.accumulatorNs)
        plotMilliseconds("swift.renderer.frame.damage_ms", timing.damageNs)
        plotMilliseconds("swift.renderer.frame.composite_ms", timing.compositeNs)
        plotMilliseconds("swift.renderer.frame.blit_ms", timing.blitNs)
        plotMilliseconds("swift.renderer.frame.frame_snap_ms", timing.frameSnapNs)
        plotMilliseconds("swift.renderer.frame.upload_snap_ms", timing.uploadSnapNs)
        plotMilliseconds("swift.renderer.frame.submit_ms", timing.submitNs)
        plotMilliseconds("swift.renderer.frame.driver_total_ms", timing.totalNs)
        plotMilliseconds(
            "swift.renderer.frame.driver_residual_ms",
            saturatingResidual(total: timing.totalNs, phases: [
                timing.planNs, timing.resolveNs, timing.accumulatorNs, timing.damageNs,
                timing.compositeNs, timing.blitNs, timing.frameSnapNs,
                timing.uploadSnapNs, timing.submitNs,
            ]))
        plotMilliseconds("swift.renderer.frame.record_total_ms", frame.recordNs)
        plotMilliseconds(
            "swift.renderer.frame.record_residual_ms",
            saturatingResidual(total: frame.recordNs, phases: [
                frame.targetWrapNs, frame.treeSnapshotNs, timing.totalNs,
            ]))
        plotMilliseconds("swift.renderer.frame.fence_export_ms", frame.backendFinalizeNs)
        plotMilliseconds("swift.renderer.frame.atomic_commit_ms", frame.backendPresentNs)
        plotMilliseconds("swift.renderer.frame.record_to_submit_ms", frame.recordToSubmitNs)
        Trace.plot("swift.renderer.frame.operations", frame.operationCount)
        Trace.plot("swift.renderer.frame.referenced_surfaces", frame.referencedSurfaceCount)
        Trace.plot("swift.renderer.frame.changed_surfaces", frame.changedSurfaceCount)
        Trace.plot("swift.renderer.frame.damage_rects", frame.damageRectCount)
        Trace.plot("swift.renderer.frame.damage_pixels", frame.damagePixelCount)
        Trace.plot("swift.renderer.frame.full_damage", UInt64(frame.fullDamage ? 1 : 0))
        for duration in frame.clientCommitToRenderNs {
            plotMilliseconds("swift.renderer.client_commit_to_render_ms", duration)
        }
        Trace.plot("swift.renderer.client_upload.enqueued", uploadStats.enqueued)
        Trace.plot("swift.renderer.client_upload.coalesced", uploadStats.coalesced)
        Trace.plot("swift.renderer.client_upload.uploaded", uploadStats.uploaded)
        Trace.plot("swift.renderer.client_upload.failed", uploadStats.failed)
        Trace.plot("swift.renderer.client_upload.pending_bytes", uploadStats.pendingBytes)
        Trace.plot(
            "swift.renderer.client_upload.full_size_owned_allocations",
            uploadStats.fullSizeOwnedAllocations)
        Trace.plot(
            "swift.renderer.client_upload.owned_allocation_bytes",
            uploadStats.ownedAllocationBytes)
        Trace.plot(
            "swift.renderer.client_upload.bytes_copied",
            uploadStats.bytesCopied)
    }

    private static func publishPresentedFrame(_ presented: PresentedCompositeFrame) {
        let submitToPageflipNs = presented.pageflipNs >= presented.atomicCommitAcceptedNs
            ? presented.pageflipNs - presented.atomicCommitAcceptedNs : 0
        Trace.plot("swift.renderer.pageflip.output_id", presented.frame.outputID)
        Trace.plot("swift.renderer.pageflip.frame_serial", presented.frame.frameSerial)
        plotMilliseconds("swift.renderer.frame.submit_to_pageflip_ms", submitToPageflipNs)
        let fences = presented.fenceTelemetry
        Trace.plot(
            "swift.renderer.frame.client_acquire_fences",
            fences.clientAcquireFenceCount)
        Trace.plot(
            "swift.renderer.frame.client_acquire_timestamp_available",
            UInt64(fences.latestClientAcquireSignalNs == nil ? 0 : 1))
        Trace.plot(
            "swift.renderer.frame.render_fence_timestamp_available",
            UInt64(fences.renderCompleteNs == nil ? 0 : 1))
        Trace.plot(
            "swift.renderer.frame.gpu_timestamp_available",
            UInt64(fences.gpuElapsedNs == nil ? 0 : 1))
        if let gpuElapsedNs = fences.gpuElapsedNs {
            plotMilliseconds("swift.renderer.frame.gpu_execution_ms", gpuElapsedNs)
        }
        if let clientAcquireNs = fences.latestClientAcquireSignalNs {
            plotSignedIntervalMilliseconds(
                "swift.renderer.frame.client_acquire_ready_after_submit_ms",
                from: presented.atomicCommitAcceptedNs, to: clientAcquireNs)
            if let renderCompleteNs = fences.renderCompleteNs {
                plotSignedIntervalMilliseconds(
                    "swift.renderer.frame.client_acquire_to_render_complete_ms",
                    from: clientAcquireNs, to: renderCompleteNs)
            }
        }
        if let renderCompleteNs = fences.renderCompleteNs {
            let submitToRenderNs = renderCompleteNs >= presented.atomicCommitAcceptedNs
                ? renderCompleteNs - presented.atomicCommitAcceptedNs : 0
            plotSignedIntervalMilliseconds(
                "swift.renderer.frame.submit_to_render_complete_ms",
                from: presented.atomicCommitAcceptedNs, to: renderCompleteNs)
            if let gpuElapsedNs = fences.gpuElapsedNs {
                plotMilliseconds(
                    "swift.renderer.frame.gpu_queue_residual_ms",
                    submitToRenderNs >= gpuElapsedNs ? submitToRenderNs - gpuElapsedNs : 0)
            }
            plotSignedIntervalMilliseconds(
                "swift.renderer.frame.render_complete_to_pageflip_ms",
                from: renderCompleteNs, to: presented.pageflipNs)
        }
        for commitToRenderNs in presented.frame.clientCommitToRenderNs {
            let clientCommitToPageflipNs = saturatingSum([
                commitToRenderNs, presented.frame.recordToSubmitNs, submitToPageflipNs,
            ])
            plotMilliseconds(
                "swift.renderer.client_commit_to_pageflip_ms",
                clientCommitToPageflipNs)
        }
    }

    /// Install the present-report seam on the render backend: `submitted` fires per
    /// output on an accepted scanout commit, `presented` on its page-flip completion
    /// with the kernel flip timestamp (ns) + vblank sequence. The composition root wires
    /// these to the output's `DisplayLink` present-id accounting, the session-lock
    /// present ack, and the client frame/feedback tick. Call after `bringUp`.
    public static func installPresentReport(
        submitted: @escaping @MainActor (
            _ outputID: UInt64,
            _ outputGeneration: UInt64,
            _ submissionID: UInt64,
            _ sampledIOSurfaceIDs: [UInt64]
        ) -> Void,
        presented: @escaping @MainActor (
            _ outputID: UInt64,
            _ outputGeneration: UInt64,
            _ submissionID: UInt64,
            _ presentationNs: UInt64,
            _ sequence: UInt64
        ) -> Void,
        discarded: @escaping @MainActor (
            _ outputID: UInt64,
            _ outputGeneration: UInt64,
            _ submissionID: UInt64
        ) -> Void
    ) {
        shared?.onOutputSubmitted = {
            outputID, outputGeneration, submissionID, frameSerial,
            acceptedNs, sampledIOSurfaceIDs in
            if let accepted = telemetryCorrelator.noteSubmission(
                outputID: outputID, frameSerial: frameSerial,
                atomicCommitAcceptedNs: acceptedNs),
               let stats = shared?.clientUploadStats {
                publishAcceptedFrame(accepted, uploadStats: stats)
            }
            submitted(
                outputID, outputGeneration, submissionID,
                sampledIOSurfaceIDs)
        }
        shared?.onOutputPresented = {
            outputID, outputGeneration, submissionID, frameSerial,
            presentationNs, sequence, fenceTelemetry in
            if let sample = telemetryCorrelator.notePageflip(
                outputID: outputID, frameSerial: frameSerial,
                pageflipNs: presentationNs,
                fenceTelemetry: fenceTelemetry) {
                publishPresentedFrame(sample)
            }
            presented(
                outputID, outputGeneration, submissionID,
                presentationNs, sequence)
        }
        shared?.onOutputPresentationDiscarded = {
            outputID, outputGeneration, submissionID, frameSerial in
            telemetryCorrelator.discard(
                outputID: outputID, frameSerial: frameSerial)
            discarded(outputID, outputGeneration, submissionID)
        }
    }

    public static func installSurfaceRetirement(
        _ retired: @escaping @MainActor (UInt32) -> Void
    ) {
        shared?.onSurfaceBufferRetired = { retired(UInt32(truncatingIfNeeded: $0)) }
    }

    /// Set the session-lock composition, per output: the raw context ids of the
    /// mapped ext-session-lock surfaces to composite over the opaque ground while
    /// locked. nil = unlocked. The render core restricts each output's scanout to
    /// these contexts — the single choke point for the `locked` invariant.
    public static func setLockComposition(_ perOutput: [UInt64: Set<UInt32>]?) {
        shared?.setLockComposition(perOutput)
    }

    /// Push this frame's per-output direct-scanout candidates, built by the
    /// composition root from the live window model. The backend evaluates each against
    /// its cached primary-plane formats and promotes eligible buffers during presentation.
    public static func setScanoutCandidates(_ perOutput: [UInt64: ScanoutCandidate]) {
        shared?.setScanoutCandidates(perOutput)
    }

    /// Upload a new cursor image to every output's hardware cursor plane.
    /// The composition root calls this only when the cursor image changes.
    public static func setCursorImage(
        pixels: [UInt8], width: UInt32, height: UInt32, hotspotX: Int32, hotspotY: Int32
    ) {
        shared?.setCursorImage(pixels: pixels, width: width, height: height,
                               hotspotX: hotspotX, hotspotY: hotspotY)
    }

    /// Update the live pointer position for the hardware cursor plane. Called each
    /// frame; re-places the plane on the next commit with no upload.
    public static func setCursorPosition(x: Double, y: Double) {
        shared?.setCursorPosition(x: x, y: y)
    }

    /// Whether any layer in the authoritative Swift tree has an in-flight animation.
    /// The frame-demand path reads this to keep driving frames while animations
    /// advance.
    public static var hasActiveAnimations: Bool {
        retainedStore?.hasActiveAnimations ?? false
    }

    /// Tear down the render runtime in GPU-lifetime order at compositor shutdown.
    public static func shutdown() {
        NucleusCompositorServer.shared.renderService = nil
        guard let runtime = shared else { return }
        if !runtime.shutdown() {
            // A presentation still owned by the kernel makes the runtime's normal
            // destructors unsafe. Intentionally retain it until process exit; the
            // compositor teardown can now continue and release the seat/VT.
            _ = Unmanaged.passRetained(runtime)
        }
        shared = nil
        retainedStore = nil
        telemetryCorrelator = PresentationTelemetryCorrelator()
    }
}
