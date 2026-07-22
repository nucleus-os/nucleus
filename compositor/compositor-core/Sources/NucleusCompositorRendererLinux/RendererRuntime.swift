// The DRM/KMS presentation backend: the Linux-specific orchestration around the
// agnostic `RenderCore`. It owns the GBM device, a `DrmOutput` (KMS atomic flip)
// per output with a double-buffered ring of GBM scanout buffers (each imported as
// a Vulkan image + a KMS framebuffer), connected-output self-enumeration, the DRM
// event pump, VT session pause/resume, and the explicit-sync (syncobj) release
// path for client buffers. It holds a `RenderCore` and conforms to
// `PresentationBackend`: `RenderCore.renderReady(backend:)` asks it to acquire the
// next ring slot's image, records the retained tree into it, and asks it to flip.
//
// LIFETIME INVARIANT (mirrors the GPU teardown contract): the only long-lived GPU
// objects this backend owns are the ring buffers' imported images (held by their
// `OutputBufferOwner`s). `shutdown()` enforces the order: the core drops its
// render resources first (accumulators + registry + imported client images), then
// every binding's ring (scanout images + BOs + KMS fbs), then the core drops the
// Graphite context and then the Vulkan device.

import VulkanC
import Vulkan
import NucleusCompositorDrmC
import NucleusRenderModel
@_spi(NucleusPlatform) import NucleusRenderer
import Glibc

/// The DRM/KMS presentation backend. Constructed at compositor bring-up with the
/// DRM master fd; outputs are attached as the display layout resolves; the reactor
/// drives `renderReadyOutputs`. `@MainActor`: the render path runs on the main-loop
/// executor alongside Wayland and DRM ownership.
@MainActor
public final class RendererRuntime: PresentationBackend {
    public var defersGpuResourceRetirement: Bool { true }
    let core: RenderCore
    public var onSurfaceBufferRetired: (@MainActor (UInt64) -> Void)?

    /// The authoritative retained tree (the core owns it; exposed for the runtime
    /// owner's tick + animation reads).
    public var store: RetainedTreeStore { core.store }
    public var clientUploadStats: RenderCore.ClientUploadStats { core.clientUploadStats }

    var gbmBox: GbmDevice?
    let gbmHandle: OpaquePointer

    /// The DRM master fd handed across `@c` at bring-up. Borrowed — the seat /
    /// device owner keeps the close obligation; the backend never closes it.
    let drmDeviceFd: Int32
    let drmCaps: DrmCaps
    let presentationClock: DrmPresentationClock
    public var presentationClockID: UInt32 {
        DrmPresentationClock.clockID
    }
    /// Render-node `dev_t` advertised through linux-dmabuf feedback.
    public var dmabufMainDevice: UInt64 = 0

    var bindings: [UInt64: RenderOutputBinding] = [:]
    /// Render-complete semaphores from GPU submissions that could not be handed to
    /// KMS (sync-file export or atomic-commit failure). Their submission serial is
    /// the lifetime fence; the main loop polls and destroys them after completion.
    var unpresentedRenderSyncs: [DrmRenderSync] = []
    var scheduledOutputIDs: Set<UInt64>?
    /// Borrowed page-flip user_data must remain valid even if a replaced driver's
    /// kernel queues a late callback. These are released with the DRM runtime.
    var retiredFlipTokens: [DrmPageFlipToken] = []
    /// Source of per-binding generations (see `RenderOutputBinding.generation`).
    var nextBindingGeneration: UInt64 = 0
    /// Last successfully attached whole-device assignment set. Topology discovery
    /// uses it to keep valid connector/CRTC/plane pipelines stable.
    var appliedTopologySnapshot: OutputTopologySnapshot?
    var nextTopologyGeneration: UInt64 = 1
    var nextPresentationSubmissionID: UInt64 = 1
    /// The most recently discovered, globally allocated topology. Discovery does
    /// not mutate live KMS state; the composition root chooses which assignments
    /// to attach and then commits the successful subset.
    var pendingTopology: (
        inventory: DrmTopologyInventory,
        result: DrmTopologyPlanningResult
    )?
    var backendState: DrmBackendState = .resuming

    /// Internal present-report seam installed by the composition root. Composite
    /// submissions carry their exact frame serial; direct scanout carries serial zero.
    /// The acceptance timestamp is sampled immediately after the successful atomic
    /// commit. Page flips carry the same serial.
    @_spi(NucleusPlatform)
    public var onOutputSubmitted: (@MainActor (
        _ outputID: UInt64, _ outputGeneration: UInt64,
        _ submissionID: UInt64, _ frameSerial: UInt64,
        _ atomicCommitAcceptedNs: UInt64, _ sampledIOSurfaceIDs: [UInt64]
    ) -> Void)?
    @_spi(NucleusPlatform)
    public var onOutputPresented: (@MainActor (
        _ outputID: UInt64, _ outputGeneration: UInt64,
        _ submissionID: UInt64, _ frameSerial: UInt64,
        _ presentationNs: UInt64, _ sequence: UInt64,
        _ fenceTelemetry: CompositeFenceTelemetry
    ) -> Void)?
    @_spi(NucleusPlatform)
    public var onOutputPresentationDiscarded: (@MainActor (
        _ outputID: UInt64,
        _ outputGeneration: UInt64,
        _ submissionID: UInt64,
        _ frameSerial: UInt64
    ) -> Void)?

    // Per-surface release syncobj points (explicit sync): signaled when the buffer
    // is no longer referenced (next upload / release / after the frame presents).
    var pendingSurfaceReleaseSync: [UInt64: DmaBufSyncPoint] = [:]
    /// Diagnostic duplicates of the acquire sync_files currently installed in the
    /// render core, consumed alongside the exact composite frame that waits on them.
    var pendingClientAcquireFenceDiagnostics: [UInt64: DiagnosticSyncFile] = [:]
    /// Release points for replaced composited buffers, ordered per surface. The
    /// render core calls back only after the retired Vulkan image is GPU-safe.
    var retiredCompositeReleaseSync: [UInt64: [DmaBufSyncPoint]] = [:]
    /// A core image retirement that belongs to a buffer still retained by direct
    /// scanout must not release the Wayland buffer until that plane rotates out.
    var suppressedCompositeRetireNotifications: [UInt64: Int] = [:]

    /// Refcounts GEM handles imported for client-buffer scanout, so two
    /// buffers sharing an underlying dmabuf don't close each other's handle.
    let gemHandleTable: GemHandleTable

    // Direct-scanout. The primary plane's advertised (format, modifier) set per
    // output, cached at attach — the last check the per-surface evaluator runs. The
    // composition root pushes one `ScanoutCandidate` per output each frame
    // (`setScanoutCandidates`); the backend evaluates it against these formats.
    var primaryPlaneFormats: [UInt64: FormatSet] = [:]
    var scanoutCandidates: [UInt64: ScanoutCandidate] = [:]
    /// Per-surface (keyed by IOSurface id) KMS-importable copy of the client's opaque
    /// dmabuf, retained for potential direct scanout. Imported to a
    /// framebuffer on demand by `clientScanoutFramebuffer`; replaced on the next commit
    /// and dropped at surface teardown.
    var clientScanoutBuffers: [UInt64: ClientScanoutBuffer] = [:]
    /// Which client surface each output is scanning out — front (latched)
    /// + pending (in-flight), rotated on flip-completion. Drives deferred client-buffer
    /// release: a buffer is held from submit until the flip that replaces it.
    var scanoutSurfaces = ScanoutSurfaceTracker()
    /// Last logged decision string per output, so the per-frame evaluation logs only
    /// on a transition (eligible ↔ a specific block reason), not every vblank.
    var lastScanoutDecision: [UInt64: String] = [:]
    var scanoutEligibilityChangeCount: UInt64 = 0

    // Hardware cursor plane. The compositor-global cursor image (retained
    // ARGB pixels + hotspot + size) and live pointer position, pushed by the composition
    // root. `setCursorImage` uploads to every output's cursor plane (rare); a per-frame
    // `setCursorPosition` only re-places the plane on the next commit — no re-upload.
    var cursorPixels: [UInt8] = []
    var cursorImageWidth: UInt32 = 0
    var cursorImageHeight: UInt32 = 0
    var cursorHotspotX: Int32 = 0
    var cursorHotspotY: Int32 = 0
    var cursorX: Double = 0
    var cursorY: Double = 0
    /// Outputs that need a present this pass to carry a cursor-plane update with no
    /// tree damage (the pointer moved / the image changed). Consumed by `wantsPresent`
    /// and cleared per output on a successful present.
    var cursorPresentDirty: Set<UInt64> = []
    var forcedPresentOutputIDs: Set<UInt64> = []
    /// The driver's max cursor size (the cursor BO dimensions), queried once. Falls
    /// back to 64×64 when the caps are unavailable.
    lazy var cursorPlaneSize: (width: UInt32, height: UInt32) = {
        return (drmCaps.cursorWidth > 0 ? UInt32(drmCaps.cursorWidth) : 64,
                drmCaps.cursorHeight > 0 ? UInt32(drmCaps.cursorHeight) : 64)
    }()

    /// Bring up the render core + the DRM/KMS backend over the DRM master fd:
    /// create the agnostic core (Vulkan instance/device, Graphite context, frame
    /// driver), then a GBM device over the fd. Returns nil when the GPU/GBM stack
    /// is unavailable (a fatal bring-up failure).
    init(
        core: RenderCore,
        gbm: consuming GbmDevice,
        gbmHandle: OpaquePointer,
        drmDeviceFd: Int32,
        drmCaps: DrmCaps
    ) {
        self.core = core
        self.gbmHandle = gbmHandle
        self.drmDeviceFd = drmDeviceFd
        self.drmCaps = drmCaps
        self.presentationClock = DrmPresentationClock(
            kernelUsesMonotonic: drmCaps.timestampMonotonic)
        self.gemHandleTable = GemHandleTable(deviceFd: drmDeviceFd)
        self.gbmBox = consume gbm
        // The core fires this when a client surface's previous backing is dropped
        // (shm upload over a dmabuf, or surface release) so the buffer's release
        // syncobj is signaled.
        core.onSurfaceReleaseSync = { [weak self] id in self?.retiredCompositeBacking(iosurfaceID: id) }
    }


    /// Allocate a fresh non-zero IOSurface id for a new client surface.
    public func allocSurfaceId() -> UInt32 { core.allocSurfaceId() }




    /// Suspend the session on VT-switch-away. This never blocks the main actor.
    /// Outstanding kernel presentation state leaves the backend in `.pausing`;
    /// the composition root retries without admitting new presents and
    /// acknowledges libseat only on a terminal result.
    @discardableResult
    public func pauseSessionChecked() -> RendererRetirementResult {
        switch backendState {
        case .inactive:
            return .complete
        case .failed:
            return .failed
        case .pausing:
            break
        case .active, .resuming:
            backendState = .pausing
        }
        switch retireOutputs(Set(bindings.keys)) {
        case .draining:
            return .draining
        case .failed:
            backendState = .failed(
                "output topology could not retire before DRM master loss")
            return .failed
        case .complete:
            break
        }
        guard DrmSession.dropMaster(fd: drmDeviceFd) else {
            backendState = .failed("drmDropMaster failed")
            return .failed
        }
        pendingTopology = nil
        backendState = .inactive
        return .complete
    }

    /// Resume starts a recovery transaction. Presentation remains disabled until
    /// the composition root discovers, applies, and commits a complete topology.
    @discardableResult
    public func resumeSessionChecked() -> Bool {
        guard case .inactive = backendState else {
            return backendState.admitsPresentation
        }
        backendState = .resuming
        guard DrmSession.setMaster(fd: drmDeviceFd) else {
            backendState = .failed("drmSetMaster failed")
            return false
        }
        guard DrmCapabilities.enableAtomicModesetting(fd: drmDeviceFd) else {
            backendState = .failed("required DRM client capabilities unavailable")
            _ = DrmSession.dropMaster(fd: drmDeviceFd)
            return false
        }
        return true
    }

    /// `PresentationBackend` lifecycle entry points. The composition root uses
    /// the checked variants above so session-control failure can fail closed.
    public func pauseSession() {
        _ = pauseSessionChecked()
    }

    public func resumeSession() {
        _ = resumeSessionChecked()
    }

    /// Disable every live output without waiting. The compositor calls this while
    /// its reactor still owns DRM readiness; `.draining` means keep the loop alive
    /// and retry while every scanout owner remains retained.
    public func prepareShutdown() -> RendererRetirementResult {
        retireOutputs(Set(bindings.keys))
    }


    // MARK: - Teardown

    /// Tear down in GPU-lifetime order: the core drops its render resources
    /// (accumulators + registry + imported client images) → every binding's scanout
    /// ring (images + BOs + KMS fbs) → the core drops Graphite and then the device.
    /// Returns `false` when kernel presentation has not retired. In that case the
    /// caller must keep this runtime alive until process exit: destroying Vulkan,
    /// GBM, or KMS resources which the kernel may still reference is unsafe, but
    /// returning promptly is required so the compositor can release its DRM
    /// session and seat.
    public func shutdown() -> Bool {
        logRendererDrm("shutdown: validating kernel scanout retirement")
        guard !bindings.values.contains(where: { $0.drm.active }) else {
            logRendererDrm(
                "shutdown: kernel scanout did not retire; abandoning GPU/KMS resources so the DRM session can close"
            )
            return false
        }
        // Queue-idle is the final device-lifetime barrier. Normal operation retires
        // unpresented submission semaphores by completion serial without blocking.
        core.waitForGpuIdle()
        unpresentedRenderSyncs.removeAll()
        guard retireOutputs(Set(bindings.keys)) == .complete else {
            logRendererDrm(
                "shutdown: scanout disable failed; preserving GPU/KMS resources")
            return false
        }
        logRendererDrm("shutdown: scanout disabled")
        core.shutdownRenderResources()
        pendingClientAcquireFenceDiagnostics.removeAll()
        primaryPlaneFormats.removeAll()
        scanoutCandidates.removeAll()
        lastScanoutDecision.removeAll()
        scanoutEligibilityChangeCount = 0
        cursorPresentDirty.removeAll()
        forcedPresentOutputIDs.removeAll()
        cursorPixels = []
        scanoutSurfaces.reset()
        for buffer in clientScanoutBuffers.values { buffer.destroy() }
        clientScanoutBuffers.removeAll()
        signalPendingSurfaceReleases()
        gbmBox = nil
        core.teardownDevice()
        logRendererDrm("shutdown: complete")
        return true
    }
}
