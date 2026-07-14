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

public struct RendererOutputInfo: Sendable, Equatable {
    public let id: UInt64
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let refreshMhz: Int32
    public let physicalWidthMM: Int32
    public let physicalHeightMM: Int32
}

@_spi(NucleusPlatform)
public struct CompositeFenceTelemetry: Sendable, Equatable {
    public var clientAcquireFenceCount: UInt64 = 0
    public var latestClientAcquireSignalNs: UInt64?
    public var renderCompleteNs: UInt64?
    public var gpuElapsedNs: UInt64?

    public init() {}
}

func logRendererDrm(_ message: String) {
    let line = Array(("renderer-drm: " + message + "\n").utf8)
    line.withUnsafeBytes { bytes in
        if let base = bytes.baseAddress { _ = Glibc.write(STDERR_FILENO, base, bytes.count) }
    }
}

func rendererErrno() -> Int32 { __errno_location().pointee }

private func rendererMonotonicNowNs() -> UInt64 {
    var timestamp = timespec()
    clock_gettime(CLOCK_MONOTONIC, &timestamp)
    return UInt64(timestamp.tv_sec) &* 1_000_000_000 &+ UInt64(timestamp.tv_nsec)
}

/// Owns a diagnostic duplicate of a sync_file. The live synchronization fd is
/// still consumed by Vulkan or KMS exactly as before; this duplicate exists only
/// long enough to read the kernel's eventual signal timestamp.
fileprivate final class DiagnosticSyncFile {
    private var fd: Int32

    init?(duplicating sourceFd: Int32) {
        guard sourceFd >= 0 else { return nil }
        let copied = dup(sourceFd)
        guard copied >= 0 else { return nil }
        fd = copied
    }

    func signalTimestampNs() -> UInt64? {
        var snapshot = nucleus_drm_sync_file_snapshot()
        guard nucleus_drm_get_sync_file_snapshot(fd, &snapshot) == 0,
              snapshot.status > 0, snapshot.latest_timestamp_ns > 0
        else { return nil }
        return snapshot.latest_timestamp_ns
    }

    deinit {
        if fd >= 0 { close(fd); fd = -1 }
    }
}

/// One double-buffer slot: the raw imported scanout image handle (copied out
/// before the BO owner consumed the noncopyable `VkOwned`), its KMS framebuffer
/// id (for `DrmOutput.commitScanout`), and the `OutputBufferOwner` kept alive for
/// teardown.
final class ScanoutSlot {
    let imageHandle: VkImage
    let fbId: UInt32
    private var owner: OutputBufferOwner?

    init(imageHandle: VkImage, fbId: UInt32, owner: consuming OutputBufferOwner) {
        self.imageHandle = imageHandle
        self.fbId = fbId
        self.owner = consume owner
    }

    /// Drop the BO owner now (fb → image → BO teardown). Idempotent.
    func release() { owner = nil }
    deinit { owner = nil }
}

/// One exportable Vulkan binary semaphore for a composited DRM frame. Graphite
/// signals it asynchronously; `exportSyncFd` transfers its payload into a Linux
/// sync_file passed to KMS. The semaphore stays alive through page-flip completion.
final class DrmRenderSync {
    let semaphore: VkSemaphore
    private let device: VkDevice
    private let dispatch: VK.DeviceDispatch
    private(set) var syncFd: Int32 = -1
    var submissionSerial: UInt64 = 0
    private var renderFenceDiagnostic: DiagnosticSyncFile?
    private var clientAcquireFenceDiagnostics: [DiagnosticSyncFile] = []

    init?(device: VkDevice, dispatch: VK.DeviceDispatch) {
        guard let create = dispatch.vkCreateSemaphore else { return nil }
        var export = VkExportSemaphoreCreateInfo()
        export.sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO
        export.handleTypes = VkExternalSemaphoreHandleTypeFlags(
            VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT.rawValue)
        var info = VkSemaphoreCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var created: VkSemaphore? = nil
        let result = withUnsafePointer(to: &export) { exportPointer in
            info.pNext = UnsafeRawPointer(exportPointer)
            return create(device, &info, nil, &created)
        }
        guard result == VK_SUCCESS, let created else { return nil }
        self.device = device
        self.dispatch = dispatch
        self.semaphore = created
    }

    func exportSyncFd() -> Bool {
        guard syncFd < 0, let getFd = dispatch.vkGetSemaphoreFdKHR else { return false }
        var info = VkSemaphoreGetFdInfoKHR()
        info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR
        info.semaphore = semaphore
        info.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT
        var fd: Int32 = -1
        guard getFd(device, &info, &fd) == VK_SUCCESS, fd >= 0 else { return false }
        syncFd = fd
        renderFenceDiagnostic = DiagnosticSyncFile(duplicating: fd)
        return true
    }

    fileprivate func attachClientAcquireFenceDiagnostics(_ diagnostics: [DiagnosticSyncFile]) {
        clientAcquireFenceDiagnostics = diagnostics
    }

    fileprivate func takeFenceTelemetry() -> CompositeFenceTelemetry {
        var telemetry = CompositeFenceTelemetry()
        telemetry.clientAcquireFenceCount = UInt64(clientAcquireFenceDiagnostics.count)
        telemetry.latestClientAcquireSignalNs = clientAcquireFenceDiagnostics.compactMap {
            $0.signalTimestampNs()
        }.max()
        telemetry.renderCompleteNs = renderFenceDiagnostic?.signalTimestampNs()
        clientAcquireFenceDiagnostics.removeAll()
        renderFenceDiagnostic = nil
        return telemetry
    }

    func closeSyncFd() {
        if syncFd >= 0 { close(syncFd); syncFd = -1 }
    }

    deinit {
        closeSyncFd()
        dispatch.vkDestroySemaphore?(device, semaphore, nil)
    }
}

/// Retained by DrmOutput while the atomic flip is pending, pairing the scanout BO
/// with the Vulkan completion semaphore whose exported fd gated that flip.
final class SubmittedCompositeScanout {
    let slot: ScanoutSlot
    let sync: DrmRenderSync
    init(slot: ScanoutSlot, sync: DrmRenderSync) { self.slot = slot; self.sync = sync }
}

/// Per-output live binding: the KMS output and its scanout ring. Reference type so
/// it lives in the backend's `[UInt64: …]` map. `currentSlot` is the slot handed
/// out by `acquireTarget` this frame, flipped by `present`.
final class RenderOutputBinding {
    let outputId: UInt64
    /// Monotonic id distinguishing this binding from a prior one under the same output
    /// id (hot re-enumerate) — page-flip completions carry it so a stale one for the
    /// old binding is rejected.
    let generation: UInt64
    let drm: DrmOutput
    let slots: [ScanoutSlot]
    let format: VkFormat
    let queueFamily: UInt32
    let width: Int32
    let height: Int32
    /// The output's logical placement + scale, for hardware cursor-plane placement.
    let logicalRect: OutputRect
    let fractionalScale: Double
    /// The hardware cursor plane, nil when the pipeline has none or allocation failed
    /// (the output then runs without a hardware cursor).
    var cursorPlane: DrmCursorPlane?
    var currentSlot: ScanoutSlot?
    var currentRenderSync: DrmRenderSync?
    var pendingRenderSync: DrmRenderSync?
    var pendingSubmissionSerial: UInt64 = 0
    private var ring: MailboxRing

    init(
        outputId: UInt64, generation: UInt64, drm: DrmOutput, slots: [ScanoutSlot],
        format: VkFormat, queueFamily: UInt32, width: Int32, height: Int32,
        logicalRect: OutputRect, fractionalScale: Double, cursorPlane: DrmCursorPlane?
    ) {
        self.outputId = outputId
        self.generation = generation
        self.drm = drm
        self.slots = slots
        self.format = format
        self.queueFamily = queueFamily
        self.width = width
        self.height = height
        self.logicalRect = logicalRect
        self.fractionalScale = fractionalScale
        self.cursorPlane = cursorPlane
        self.ring = MailboxRing(capacity: slots.count)
    }

    /// Pick the next ring slot to render into (round-robin).
    func nextSlot() -> ScanoutSlot { slots[ring.acquireSlot()] }

    /// Drop the scanout ring (images + BOs + KMS fbs). Called by the backend AFTER
    /// the core has released its render resources and BEFORE the device tears down.
    @discardableResult
    func teardown() -> Bool {
        // Blank the CRTC (a blocking modeset, which also clears the cursor plane)
        // before destroying the framebuffers, so the kernel is no longer scanning any
        // of them when the slot ring + cursor BOs drop. If the blank failed (a flip was
        // still in flight → -EBUSY), the kernel may still be scanning a framebuffer we
        // are about to drop — log it (a full drain-then-retry is a follow-up).
        if !drm.disableScanout() {
            logScanout("output \(outputId): disableScanout failed at teardown (flip in flight?)")
            return false
        }
        cursorPlane?.destroy()
        cursorPlane = nil
        for slot in slots { slot.release() }
        return true
    }
}

/// The DRM/KMS presentation backend. Constructed at compositor bring-up with the
/// DRM master fd; outputs are attached as the display layout resolves; the reactor
/// drives `renderReadyOutputs`. `@MainActor`: the render path runs on the main-loop
/// thread; the `@c` reactor entries enter via `MainActor.assumeIsolated`.
@MainActor
public final class RendererRuntime: PresentationBackend {
    public var defersGpuResourceRetirement: Bool { true }
    private let core: RenderCore
    public var onSurfaceBufferRetired: (@MainActor (UInt64) -> Void)?

    /// The authoritative retained tree (the core owns it; exposed for the runtime
    /// owner's tick + animation reads).
    public var store: RetainedTreeStore { core.store }
    public var clientUploadStats: RenderCore.ClientUploadStats { core.clientUploadStats }

    private var gbmBox: GbmDevice?
    private let gbmHandle: OpaquePointer

    /// The DRM master fd handed across `@c` at bring-up. Borrowed — the seat /
    /// device owner keeps the close obligation; the backend never closes it.
    private let drmDeviceFd: Int32

    private var bindings: [UInt64: RenderOutputBinding] = [:]
    /// Borrowed page-flip user_data must remain valid even if a replaced driver's
    /// kernel queues a late callback. These are released with the DRM runtime.
    private var retiredFlipTokens: [DrmPageFlipToken] = []
    /// Source of per-binding generations (see `RenderOutputBinding.generation`).
    private var nextBindingGeneration: UInt64 = 0

    /// Internal present-report seam installed by the composition root. Composite
    /// submissions carry their exact frame serial; direct scanout carries serial zero.
    /// The acceptance timestamp is sampled immediately after the successful atomic
    /// commit. Page flips carry the same serial.
    @_spi(NucleusPlatform)
    public var onOutputSubmitted: (@MainActor (
        _ outputID: UInt64, _ frameSerial: UInt64, _ atomicCommitAcceptedNs: UInt64
    ) -> Void)?
    @_spi(NucleusPlatform)
    public var onOutputPresented: (@MainActor (
        _ outputID: UInt64, _ frameSerial: UInt64,
        _ presentationNs: UInt64, _ sequence: UInt64,
        _ fenceTelemetry: CompositeFenceTelemetry
    ) -> Void)?

    // Per-surface release syncobj points (explicit sync): signaled when the buffer
    // is no longer referenced (next upload / release / after the frame presents).
    private var pendingSurfaceReleaseSync: [UInt64: DmaBufSyncPoint] = [:]
    /// Diagnostic duplicates of the acquire sync_files currently installed in the
    /// render core, consumed alongside the exact composite frame that waits on them.
    private var pendingClientAcquireFenceDiagnostics: [UInt64: DiagnosticSyncFile] = [:]
    /// Release points for replaced composited buffers, ordered per surface. The
    /// render core calls back only after the retired Vulkan image is GPU-safe.
    private var retiredCompositeReleaseSync: [UInt64: [DmaBufSyncPoint]] = [:]
    /// A core image retirement that belongs to a buffer still retained by direct
    /// scanout must not release the Wayland buffer until that plane rotates out.
    private var suppressedCompositeRetireNotifications: [UInt64: Int] = [:]

    /// Refcounts GEM handles imported for client-buffer scanout, so two
    /// buffers sharing an underlying dmabuf don't close each other's handle.
    private let gemHandleTable: GemHandleTable

    // Direct-scanout. The primary plane's advertised (format, modifier) set per
    // output, cached at attach — the last check the per-surface evaluator runs. The
    // composition root pushes one `ScanoutCandidate` per output each frame
    // (`setScanoutCandidates`); the backend evaluates it against these formats.
    private var primaryPlaneFormats: [UInt64: FormatSet] = [:]
    private var scanoutCandidates: [UInt64: ScanoutCandidate] = [:]
    /// Per-surface (keyed by IOSurface id) KMS-importable copy of the client's opaque
    /// dmabuf, retained for potential direct scanout. Imported to a
    /// framebuffer on demand by `clientScanoutFramebuffer`; replaced on the next commit
    /// and dropped at surface teardown.
    private var clientScanoutBuffers: [UInt64: ClientScanoutBuffer] = [:]
    /// Which client surface each output is scanning out — front (latched)
    /// + pending (in-flight), rotated on flip-completion. Drives deferred client-buffer
    /// release: a buffer is held from submit until the flip that replaces it.
    private var scanoutSurfaces = ScanoutSurfaceTracker()
    /// Last logged decision string per output, so the per-frame evaluation logs only
    /// on a transition (eligible ↔ a specific block reason), not every vblank.
    private var lastScanoutDecision: [UInt64: String] = [:]

    // Hardware cursor plane. The compositor-global cursor image (retained
    // ARGB pixels + hotspot + size) and live pointer position, pushed by the composition
    // root. `setCursorImage` uploads to every output's cursor plane (rare); a per-frame
    // `setCursorPosition` only re-places the plane on the next commit — no re-upload.
    private var cursorPixels: [UInt8] = []
    private var cursorImageWidth: UInt32 = 0
    private var cursorImageHeight: UInt32 = 0
    private var cursorHotspotX: Int32 = 0
    private var cursorHotspotY: Int32 = 0
    private var cursorX: Double = 0
    private var cursorY: Double = 0
    /// Outputs that need a present this pass to carry a cursor-plane update with no
    /// tree damage (the pointer moved / the image changed). Consumed by `wantsPresent`
    /// and cleared per output on a successful present.
    private var cursorPresentDirty: Set<UInt64> = []
    /// The driver's max cursor size (the cursor BO dimensions), queried once. Falls
    /// back to 64×64 when the caps are unavailable.
    private lazy var cursorPlaneSize: (width: UInt32, height: UInt32) = {
        let caps = DrmCapabilities.discover(fd: drmDeviceFd)
        return (caps.cursorWidth > 0 ? UInt32(caps.cursorWidth) : 64,
                caps.cursorHeight > 0 ? UInt32(caps.cursorHeight) : 64)
    }()

    /// Bring up the render core + the DRM/KMS backend over the DRM master fd:
    /// create the agnostic core (Vulkan instance/device, Graphite context, frame
    /// driver), then a GBM device over the fd. Returns nil when the GPU/GBM stack
    /// is unavailable (a fatal bring-up failure).
    public static func create(drmDeviceFd: Int32) -> RendererRuntime? {
        var deviceStat = stat()
        guard fstat(drmDeviceFd, &deviceStat) == 0 else { return nil }
        let deviceID = UInt64(deviceStat.st_rdev)
        let targetMajor = Int64(((deviceID >> 8) & 0xfff) | ((deviceID >> 32) & ~0xfff))
        let targetMinor = Int64((deviceID & 0xff) | ((deviceID >> 12) & ~0xff))
        let validationEnabled = getenv("NUCLEUS_VK_VALIDATE").map {
            String(cString: $0) == "1"
        } ?? false
        logRendererDrm(
            "selecting Vulkan device matching DRM primary \(targetMajor):\(targetMinor) " +
            "validation=\(validationEnabled)")
        guard let bootstrap = VulkanBootstrap.create(
            applicationName: "Nucleus Compositor",
            enableValidation: validationEnabled)
        else {
            logRendererDrm(
                "Vulkan instance bootstrap failed validation=\(validationEnabled)")
            return nil
        }
        guard let core = RenderCore.create(
                bootstrap: bootstrap,
                qualification: .platformProbe { instance, physicalDevice, _ in
                    guard let raw = vkGetInstanceProcAddr(
                        instance.vkInstance, "vkGetPhysicalDeviceProperties2")
                    else { return false }
                    let getProperties = unsafeBitCast(raw, to: PFN_vkGetPhysicalDeviceProperties2.self)
                    var drm = VkPhysicalDeviceDrmPropertiesEXT()
                    drm.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT
                    var properties = VkPhysicalDeviceProperties2()
                    properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
                    withUnsafeMutablePointer(to: &drm) { drmPointer in
                        properties.pNext = UnsafeMutableRawPointer(drmPointer)
                        getProperties(physicalDevice.vkPhysicalDevice, &properties)
                    }
                    let matches = drm.hasPrimary != 0
                        && drm.primaryMajor == targetMajor
                        && drm.primaryMinor == targetMinor
                    logRendererDrm("Vulkan candidate primary=\(drm.hasPrimary != 0 ? "\(drm.primaryMajor):\(drm.primaryMinor)" : "none") render=\(drm.hasRender != 0 ? "\(drm.renderMajor):\(drm.renderMinor)" : "none") match=\(matches)")
                    return matches
                })
        else { logRendererDrm("no Vulkan device matched the selected DRM primary node"); return nil }
        guard let gbm = GbmDevice(borrowingFd: drmDeviceFd), let gbmHandle = gbm.handle else {
            logRendererDrm("gbm_create_device failed errno=\(rendererErrno())")
            return nil
        }
        logRendererDrm("Vulkan and GBM initialized on selected DRM device")
        return RendererRuntime(core: core, gbm: consume gbm, gbmHandle: gbmHandle, drmDeviceFd: drmDeviceFd)
    }

    private init(core: RenderCore, gbm: consuming GbmDevice, gbmHandle: OpaquePointer, drmDeviceFd: Int32) {
        self.core = core
        self.gbmHandle = gbmHandle
        self.drmDeviceFd = drmDeviceFd
        self.gemHandleTable = GemHandleTable(deviceFd: drmDeviceFd)
        self.gbmBox = consume gbm
        // The core fires this when a client surface's previous backing is dropped
        // (shm upload over a dmabuf, or surface release) so the buffer's release
        // syncobj is signaled.
        core.onSurfaceReleaseSync = { [weak self] id in self?.retiredCompositeBacking(iosurfaceID: id) }
    }

    /// Allocate a fresh non-zero IOSurface id for a new client surface.
    public func allocSurfaceId() -> UInt32 { core.allocSurfaceId() }

    // MARK: - Output attach

    /// Attach one KMS output: allocate a double-buffered scanout ring (GBM BO →
    /// Vulkan image → KMS framebuffer per slot), construct the `DrmOutput`, and
    /// register the output's presentation geometry with the core. Returns false on
    /// any allocation failure (the partially-allocated ring tears down via ARC).
    @discardableResult
    public func attachOutput(
        outputId: UInt64,
        logicalX: Double, logicalY: Double, logicalWidth: Double, logicalHeight: Double,
        pixelWidth: UInt32, pixelHeight: UInt32, fractionalScale: Double,
        connectorId: UInt32, crtcId: UInt32, planeId: UInt32, cursorPlaneId: UInt32,
        modeBlobId: UInt32, vrrCapable: Bool, drmFourcc: UInt32 = DrmFourcc.xrgb8888,
        ringDepth: Int = 2
    ) -> Bool {
        let generation = nextBindingGeneration
        nextBindingGeneration &+= 1
        guard let drm = DrmOutput.discover(
            deviceFd: drmDeviceFd, connectorId: connectorId, crtcId: crtcId,
            planeId: planeId, cursorPlaneId: cursorPlaneId, modeBlobId: modeBlobId,
            width: pixelWidth, height: pixelHeight, vrrCapable: vrrCapable,
            onPageFlip: { [weak self] event in
                self?.notePageFlipComplete(outputId, generation, event)
            }
        ) else {
            logRendererDrm("connector \(connectorId): required atomic properties unavailable")
            // No aggregate took ownership of the caller-created MODE_ID blob, so free
            // it here (otherwise it leaks on every failed attach). On success the
            // DrmOutput owns it and frees it in deinit.
            if modeBlobId != 0 { _ = drmModeDestroyPropertyBlob(drmDeviceFd, modeBlobId) }
            return false
        }
        guard drm.supportsInFence else {
            logRendererDrm(
                "connector \(connectorId): primary plane lacks required IN_FENCE_FD")
            return false
        }

        var slots: [ScanoutSlot] = []
        slots.reserveCapacity(ringDepth)
        for slotIndex in 0..<ringDepth {
            guard let slot = makeScanoutSlot(width: pixelWidth, height: pixelHeight, drmFormat: drmFourcc) else {
                logRendererDrm("connector \(connectorId): scanout slot \(slotIndex) allocation failed")
                return false  // already-built slots in `slots` tear down on return
            }
            slots.append(slot)
        }

        // Replacing an existing output (re-enumerate / hot-replug): tear its ring
        // down first — blank the CRTC (blocking modeset), then drop its scanout
        // images/BOs/KMS fbs — so the kernel stops scanning the old framebuffers
        // before they are destroyed. An in-flight page-flip token survives via its
        // kernel retain, so a late completion cannot read freed memory.
        if let existing = bindings[outputId] {
            guard retireBinding(existing) else {
                logRendererDrm("output \(outputId): replacement deferred; prior flip did not retire")
                return false
            }
        }
        // The re-attached output starts fresh — forget any stale scanout tracking for
        // the prior binding (a stray completion for it is also rejected by generation).
        scanoutSurfaces.removeOutput(outputId)
        // The hardware cursor plane (nil if the pipeline has none). Seed it with the
        // current cursor image so a hot-plugged output shows the pointer immediately.
        let cursorPlane = DrmCursorPlane.create(
            gbmDevice: gbmHandle, deviceFd: drmDeviceFd, planeId: cursorPlaneId, crtcId: crtcId,
            props: drm.cursorProps, width: cursorPlaneSize.width, height: cursorPlaneSize.height)
        if let cursorPlane, !cursorPixels.isEmpty {
            cursorPlane.upload(pixels: cursorPixels,
                               srcWidth: Int(cursorImageWidth), srcHeight: Int(cursorImageHeight))
        }
        bindings[outputId] = RenderOutputBinding(
            outputId: outputId, generation: generation, drm: drm, slots: slots,
            format: vulkanFormatForDrm(drmFourcc), queueFamily: core.graphicsFamily,
            width: Int32(pixelWidth), height: Int32(pixelHeight),
            logicalRect: OutputRect(x: logicalX, y: logicalY, width: logicalWidth, height: logicalHeight),
            fractionalScale: fractionalScale, cursorPlane: cursorPlane)
        // Cache the primary plane's advertised (format, modifier) set for the
        // direct-scanout modifier check (M2). Re-attach overwrites it.
        primaryPlaneFormats[outputId] = collectPlaneFormats(fd: drmDeviceFd, planeId: planeId)
        core.attachOutputGeometry(
            outputID: outputId,
            logicalX: logicalX, logicalY: logicalY, logicalWidth: logicalWidth, logicalHeight: logicalHeight,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, fractionalScale: fractionalScale)
        logRendererDrm(
            "connector \(connectorId): attached \(pixelWidth)x\(pixelHeight) crtc=\(crtcId) " +
            "primary_plane=\(planeId) explicit_render_fence=\(drm.supportsInFence)")
        return true
    }

    /// Allocate one scanout BO, import it as a Vulkan image, add a KMS framebuffer
    /// over its planes, and package the coupled lifetimes. The raw image handle is
    /// copied out before `makeOwner` consumes the buffer; the fb id ownership moves
    /// into the `OutputBufferOwner` (it issues `drmModeRmFB` on teardown).
    private func makeScanoutSlot(width: UInt32, height: UInt32, drmFormat: UInt32) -> ScanoutSlot? {
        guard let buffer = GbmScanoutBuffer.allocate(
            gbmDevice: gbmHandle, drmFormat: drmFormat, width: width, height: height,
            modifiers: [], usage: .scanout, device: core.deviceHandle, dispatch: core.deviceDispatch
        ) else { logRendererDrm("GBM scanout buffer/Vulkan DMA-BUF import failed"); return nil }

        let imageHandle = buffer.image.handle  // VkImage, Copyable

        // KMS framebuffer over the BO planes (modifier-explicit scanout path).
        let handles = buffer.planes.map { $0.handle }
        let pitches = buffer.planes.map { $0.stride }
        let offsets = buffer.planes.map { $0.offset }
        let modifiers = buffer.planes.map { _ in buffer.modifier }
        guard let fb = DrmFramebuffer(
            deviceFd: drmDeviceFd, width: width, height: height, pixelFormat: drmFormat,
            handles: handles, pitches: pitches, offsets: offsets, modifiers: modifiers
        ) else {
            logRendererDrm("drmModeAddFB2WithModifiers failed errno=\(rendererErrno()) modifier=\(buffer.modifier)")
            _ = buffer.makeOwner()
            return nil
        }
        let fbId = fb.fbId

        // Move the fb id into the owner: it removes the fb (and then the image +
        // BO) on teardown.
        let owner = buffer.makeOwner(framebufferFd: drmDeviceFd, framebufferId: fb.release())
        return ScanoutSlot(imageHandle: imageHandle, fbId: fbId, owner: consume owner)
    }

    /// Render every output with pending damage (the reactor's vblank entry).
    @discardableResult
    public func renderReadyOutputs() -> Bool {
        core.renderReady(backend: self)
    }

    /// Drain telemetry for frames actually recorded since the previous call.
    @_spi(NucleusPlatform)
    public func takeFrameTelemetry() -> [RenderFrameTelemetry] {
        core.takeFrameTelemetry()
    }

    /// Push this frame's per-output direct-scanout candidates. The composition
    /// root builds these from the live window model and calls this before the render
    /// pass, mirroring `setLockComposition`. Decision changes are logged here and
    /// `tryDirectScanout` consumes the evaluated candidate during presentation.
    public func setScanoutCandidates(_ perOutput: [UInt64: ScanoutCandidate]) {
        scanoutCandidates = perOutput
        for (outputID, candidate) in perOutput {
            guard let formats = primaryPlaneFormats[outputID] else { continue }
            let reason = candidate.evaluate(primaryPlaneFormats: formats).reason
            if lastScanoutDecision[outputID] != reason {
                lastScanoutDecision[outputID] = reason
                logScanout("output \(outputID): direct-scanout \(reason)")
            }
        }
        // Forget decisions for outputs that are no longer present.
        lastScanoutDecision = lastScanoutDecision.filter { perOutput[$0.key] != nil }
    }

    /// This output's combined direct-scanout decision from the last-pushed candidate,
    /// evaluated against its cached primary-plane formats. nil when the output has no
    /// candidate or no cached formats.
    func evaluateScanout(_ outputID: UInt64) -> ScanoutEligibility? {
        guard let candidate = scanoutCandidates[outputID],
              let formats = primaryPlaneFormats[outputID] else { return nil }
        return candidate.evaluate(primaryPlaneFormats: formats)
    }

    // MARK: - Hardware cursor

    /// Replace the cursor image (tightly-packed ARGB8888, `width × height`) and upload
    /// it to every output's cursor plane. Called by the composition root only when the
    /// cursor's generation changes, so per-frame position updates cost no upload.
    public func setCursorImage(
        pixels: [UInt8], width: UInt32, height: UInt32, hotspotX: Int32, hotspotY: Int32
    ) {
        cursorPixels = pixels
        cursorImageWidth = width
        cursorImageHeight = height
        cursorHotspotX = hotspotX
        cursorHotspotY = hotspotY
        for binding in bindings.values {
            binding.cursorPlane?.upload(pixels: pixels, srcWidth: Int(width), srcHeight: Int(height))
            cursorPresentDirty.insert(binding.outputId)
        }
    }

    /// Update the live pointer position (logical, compositor-global). Re-places the
    /// cursor plane on the next commit; no upload. Only when the position actually
    /// changes does it mark outputs for a forced present, so a stationary pointer (the
    /// root pushes position every frame) never forces needless recomposites.
    public func setCursorPosition(x: Double, y: Double) {
        guard x != cursorX || y != cursorY else { return }
        cursorX = x
        cursorY = y
        for binding in bindings.values where binding.cursorPlane != nil {
            cursorPresentDirty.insert(binding.outputId)
        }
    }

    public func wantsPresent(_ outputID: UInt64) -> Bool { cursorPresentDirty.contains(outputID) }

    /// The cursor-plane state for `binding`'s next commit: the front cursor fb + its
    /// placement, or nil when the output has no cursor plane / no image. A nil
    /// placement (pointer off this output) clears the plane in the commit.
    private func cursorCommitState(for binding: RenderOutputBinding) -> CursorCommitState? {
        guard let plane = binding.cursorPlane, plane.frontFbId != 0 else { return nil }
        let placement = plane.placement(
            outputRect: binding.logicalRect, fractionalScale: binding.fractionalScale,
            cursorX: cursorX, cursorY: cursorY, hotspotX: cursorHotspotX, hotspotY: cursorHotspotY)
        return CursorCommitState(fbId: plane.frontFbId, placement: placement)
    }

    /// Set the session-lock composition on the render core: per output, the raw
    /// context ids of the mapped ext-session-lock surfaces to composite over the
    /// opaque ground. nil = unlocked (normal composition). Called each frame by the
    /// composition root from the authoritative window model.
    public func setLockComposition(_ perOutput: [UInt64: Set<UInt32>]?) {
        core.setLockComposition(perOutput.map { dict in
            dict.mapValues { raws in Set(raws.map { ContextID(raw: $0) }) }
        })
    }

    /// Drain a completed page flip for `outputId`, freeing it to render again, and
    /// report it upward with the kernel's real flip timestamp + vblank sequence (not a
    /// re-sampled wall clock) so presentation feedback and pacing see true present time.
    func notePageFlipComplete(_ outputId: UInt64, _ generation: UInt64, _ event: DrmPageFlipEvent) {
        // Reject a completion the kernel queued for a prior binding of this output id
        // (a hot re-enumerate replaced the binding under the same key): routing it to
        // the new binding would prematurely rotate its scanout and drop a slot the
        // kernel just started scanning.
        guard let binding = bindings[outputId], binding.generation == generation else { return }
        let completedSubmissionSerial = binding.pendingSubmissionSerial
        binding.pendingSubmissionSerial = 0
        var fenceTelemetry = completedSubmissionSerial != 0
            ? binding.pendingRenderSync?.takeFenceTelemetry() ?? CompositeFenceTelemetry()
            : CompositeFenceTelemetry()
        if completedSubmissionSerial != 0 {
            // Poll Graphite before either reference to a Vulkan render semaphore can
            // drop. The pageflip proves the sync_file fired, but validation still
            // requires the owning queue completion to be observed before destroy.
            fenceTelemetry.gpuElapsedNs = core.takeCompletedSubmissionGpuElapsedNs(
                completedSubmissionSerial)
            core.releaseRetiredGpuResources(
                completedSubmissionSerial: completedSubmissionSerial)
        }
        binding.pendingRenderSync = nil
        binding.drm.notePageFlipComplete()
        // Rotate the scanned surface: the in-flight (pending) commit is now latched.
        scanoutSurfaces.flipCompleted(output: outputId)
        onOutputPresented?(
            outputId, completedSubmissionSerial,
            event.timestampNs, UInt64(event.sequence), fenceTelemetry)
    }

    // MARK: - PresentationBackend

    public func presentableOutputIDs() -> [UInt64] { Array(bindings.keys) }

    public func isReadyToPresent(_ outputID: UInt64) -> Bool {
        guard let binding = bindings[outputID] else { return false }
        return !binding.drm.pageFlipPending
    }

    public func acquireTarget(_ outputID: UInt64) -> AcquiredFrameTarget? {
        guard let binding = bindings[outputID] else { return nil }
        guard let renderSync = DrmRenderSync(
            device: core.deviceHandle, dispatch: core.deviceDispatch)
        else {
            logScanout("output \(outputID): failed to allocate required explicit render fence")
            return nil
        }
        let slot = binding.nextSlot()
        binding.currentSlot = slot
        binding.currentRenderSync = renderSync
        return AcquiredFrameTarget(
            image: slot.imageHandle, width: binding.width, height: binding.height,
            format: binding.format, tiling: VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED, queueFamily: binding.queueFamily,
            hasAlpha: false, kind: .drmScanout, signalSemaphore: renderSync.semaphore)
    }

    public func didSubmitTarget(_ outputID: UInt64) -> Bool {
        guard let binding = bindings[outputID] else { return false }
        guard let sync = binding.currentRenderSync else { return false }
        guard sync.exportSyncFd() else {
            logScanout("output \(outputID): vkGetSemaphoreFdKHR failed")
            for surfaceID in core.lastFrameAcquiredSurfaceIDs {
                pendingClientAcquireFenceDiagnostics[surfaceID] = nil
            }
            // Error-only recovery: Graphite may already have queued work against
            // this semaphore. Drain before releasing it; normal frames never stall.
            core.waitForGpuIdle()
            core.releaseRetiredGpuResources(
                completedSubmissionSerial: core.lastSubmittedSerial)
            binding.currentRenderSync = nil
            return false
        }
        sync.submissionSerial = core.lastSubmittedSerial
        sync.attachClientAcquireFenceDiagnostics(
            core.lastFrameAcquiredSurfaceIDs.compactMap {
                pendingClientAcquireFenceDiagnostics.removeValue(forKey: $0)
            })
        return true
    }

    public func discardAcquiredTarget(_ outputID: UInt64) {
        guard let binding = bindings[outputID] else { return }
        if binding.currentRenderSync != nil {
            // A failed record may have submitted no work, while a failed Graphite
            // submit may still reference the semaphore. Drain only on this error path.
            core.waitForGpuIdle()
        }
        binding.currentRenderSync = nil
        binding.currentSlot = nil
    }

    public func present(_ outputID: UInt64) -> Bool {
        guard let binding = bindings[outputID], let slot = binding.currentSlot,
              let sync = binding.currentRenderSync, sync.syncFd >= 0
        else { return false }
        // Retain the slot for the page-flip's duration: the kernel scans this
        // framebuffer until the flip completes, so it must outlive the render ring
        // rotating `currentSlot` away or the binding being torn down.
        let cursor = cursorCommitState(for: binding)
        let needsModeset = !binding.drm.active
        var rc = binding.drm.commitScanout(
            retaining: SubmittedCompositeScanout(slot: slot, sync: sync),
            fbId: slot.fbId, requestedVrr: false, modeset: needsModeset,
            inFenceFd: sync.syncFd, cursor: cursor)
        if rc != 0, cursor != nil {
            // The atomic commit is all-or-nothing: if the driver rejected the cursor
            // plane's state (format/size/position), retry without it and disable the
            // hardware cursor for this output, so a cursor-plane incompatibility can
            // never wedge presentation.
            rc = binding.drm.commitScanout(
                retaining: SubmittedCompositeScanout(slot: slot, sync: sync),
                fbId: slot.fbId, requestedVrr: false, modeset: needsModeset,
                inFenceFd: sync.syncFd, cursor: nil)
            if rc == 0 {
                logScanout("output \(outputID): cursor-plane commit rejected; disabling hardware cursor")
                binding.cursorPlane?.destroy()
                binding.cursorPlane = nil
            }
        }
        if rc == 0 {
            let atomicCommitAcceptedNs = rendererMonotonicNowNs()
            binding.pendingSubmissionSerial = sync.submissionSerial
            binding.pendingRenderSync = sync
            sync.closeSyncFd()
            binding.currentRenderSync = nil
            binding.currentSlot = nil
            // This output submitted a composite frame — no client surface is in-flight.
            // Its previously-scanned buffer (if any) stays latched until this flip
            // completes, when the tracker rotates it out and its deferred release fires.
            scanoutSurfaces.submitComposite(output: outputID)
            cursorPresentDirty.remove(outputID)
            onOutputSubmitted?(
                outputID, sync.submissionSerial, atomicCommitAcceptedNs)
        } else {
            sync.closeSyncFd()
            core.waitForGpuIdle()
            core.releaseRetiredGpuResources(
                completedSubmissionSerial: core.lastSubmittedSerial)
            binding.currentRenderSync = nil
            binding.currentSlot = nil
            binding.pendingRenderSync = nil
            logScanout("output \(outputID): atomic scanout commit failed rc=\(rc) errno=\(rendererErrno()) modeset=\(needsModeset)")
        }
        return rc == 0
    }

    /// A presented frame must not release client buffers: an unreplaced surface is
    /// re-sampled on every later frame (a static surface while other surfaces keep
    /// the loop presenting), so its buffer stays held. Explicit-sync releases fire on
    /// buffer replace (`registerSurfaceDmabuf`) and at surface teardown
    /// (`releaseSurfaceTexture`) — mirroring `wl_buffer.release` and the WSI backend's
    /// no-op. (`signalPendingSurfaceReleases` remains for `shutdown`, where releasing
    /// every held buffer at once is correct.)
    public func didPresentFrame() {}

    // MARK: - DRM ownership: self-enumeration, events, session

    // Standard KMS plane "type" enum values.
    private static let planeTypeOverlay: UInt64 = 0
    private static let planeTypePrimary: UInt64 = 1
    private static let planeTypeCursor: UInt64 = 2

    /// Self-enumerate every connected DRM output over the master fd and attach it.
    /// For each connected connector: select its CRTC, a primary plane and optional
    /// cursor plane bound to that CRTC, and create a MODE_ID blob from the preferred
    /// mode. The output id is the connector id; geometry is derived from the mode
    /// (logical = pixels / scale). Returns the count attached.
    @discardableResult
    public func enumerateAndAttachConnectedOutputs(fractionalScale: Double = 1.0) -> [RendererOutputInfo] {
        guard DrmCapabilities.enableAtomicModesetting(fd: drmDeviceFd) else {
            logRendererDrm("failed to enable universal planes/atomic modesetting errno=\(rendererErrno())")
            return []
        }
        guard let resources = DrmResources(fd: drmDeviceFd) else {
            logRendererDrm("drmModeGetResources failed errno=\(rendererErrno())")
            return []
        }
        let crtcIds = resources.crtcIds
        let connectorIds = resources.connectorIds
        logRendererDrm("enumerating connectors=\(connectorIds) crtcs=\(crtcIds)")
        let scale = fractionalScale > 0 ? fractionalScale : 1.0
        var attached: [RendererOutputInfo] = []
        for connectorId in connectorIds {
            guard let connector = DrmConnector(fd: drmDeviceFd, connectorId: connectorId) else {
                logRendererDrm("connector \(connectorId): drmModeGetConnector failed errno=\(rendererErrno())")
                continue
            }
            guard connector.isConnected else { continue }
            logRendererDrm("connector \(connectorId): connected modes=\(connector.modes.count) encoder=\(connector.encoderId)")
            guard let crtcId = selectCrtc(connector: connector, crtcIds: crtcIds) else {
                logRendererDrm("connector \(connectorId): no compatible CRTC")
                continue
            }
            guard let planes = selectPlanes(crtcId: crtcId, crtcIds: crtcIds) else {
                logRendererDrm("connector \(connectorId): no compatible primary plane for CRTC \(crtcId)")
                continue
            }
            guard let mode = connector.createPreferredModeBlob(fd: drmDeviceFd) else {
                logRendererDrm("connector \(connectorId): preferred mode blob creation failed errno=\(rendererErrno())")
                continue
            }
            logRendererDrm(
                "connector \(connectorId): selected mode \(mode.width)x\(mode.height)@\(Double(mode.refreshMhz) / 1_000.0)Hz")
            // Adaptive sync (M3) is available only when the connector advertises
            // `vrr_capable`; the CRTC's VRR_ENABLED presence is confirmed separately by
            // the atomic-prop discovery (VrrState also requires it via `crtcVrrEnabled`).
            let vrrCapable = (DrmProperties.findValue(
                fd: drmDeviceFd, objectId: connectorId, kind: .connector, name: "vrr_capable") ?? 0) != 0
            let ok = attachOutput(
                outputId: UInt64(connectorId),
                logicalX: 0, logicalY: 0,
                logicalWidth: Double(mode.width) / scale, logicalHeight: Double(mode.height) / scale,
                pixelWidth: mode.width, pixelHeight: mode.height, fractionalScale: scale,
                connectorId: connectorId, crtcId: crtcId, planeId: planes.primary,
                cursorPlaneId: planes.cursor, modeBlobId: mode.blobId, vrrCapable: vrrCapable)
            if ok {
                attached.append(RendererOutputInfo(
                    id: UInt64(connectorId),
                    pixelWidth: mode.width,
                    pixelHeight: mode.height,
                    refreshMhz: mode.refreshMhz,
                    physicalWidthMM: Int32(connector.mmWidth),
                    physicalHeightMM: Int32(connector.mmHeight)))
            } else {
                logRendererDrm("connector \(connectorId): output attachment failed")
            }
        }
        logRendererDrm("attached outputs=\(attached.count)")
        return attached
    }

    /// The CRTC driving `connector`: its current encoder's CRTC when bound, else
    /// the first of its possible encoders' first compatible CRTC. nil when none.
    private func selectCrtc(connector: borrowing DrmConnector, crtcIds: [UInt32]) -> UInt32? {
        if connector.encoderId != 0, let enc = DrmEncoder(fd: drmDeviceFd, encoderId: connector.encoderId),
           enc.crtcId != 0 {
            return enc.crtcId
        }
        for encoderId in connector.encoderIds {
            guard let enc = DrmEncoder(fd: drmDeviceFd, encoderId: encoderId) else { continue }
            for (index, crtcId) in crtcIds.enumerated() where (enc.possibleCrtcs & (UInt32(1) << UInt32(index))) != 0 {
                return crtcId
            }
        }
        return nil
    }

    /// The primary (and optional cursor) plane bound to `crtcId`. nil when no
    /// primary plane is compatible.
    private func selectPlanes(crtcId: UInt32, crtcIds: [UInt32]) -> (primary: UInt32, cursor: UInt32)? {
        guard let planeRes = DrmPlaneResources(fd: drmDeviceFd) else { return nil }
        let crtcIndex = crtcIds.firstIndex(of: crtcId)
        var primary: UInt32 = 0
        var cursor: UInt32 = 0
        for planeId in planeRes.planeIds {
            guard let plane = DrmPlane(fd: drmDeviceFd, planeId: planeId) else { continue }
            if let crtcIndex, (plane.possibleCrtcs & (UInt32(1) << UInt32(crtcIndex))) == 0 { continue }
            let type = DrmProperties.findValue(
                fd: drmDeviceFd, objectId: planeId, kind: .plane, name: "type")
                ?? RendererRuntime.planeTypeOverlay
            if type == RendererRuntime.planeTypePrimary, primary == 0 {
                primary = planeId
            } else if type == RendererRuntime.planeTypeCursor, cursor == 0 {
                cursor = planeId
            }
        }
        return primary != 0 ? (primary, cursor) : nil
    }

    /// Drain any pending DRM events on the master fd (the reactor's DRM-readiness
    /// handler calls this). Page-flip completions route through each output's flip
    /// token to `notePageFlipComplete`.
    public func handleDrmEvents() {
        _ = DrmEventPump.dispatchIfReady(fd: drmDeviceFd)
    }

    /// Wait for an accepted nonblocking flip to produce its event. Destruction is
    /// forbidden while this returns false because KMS may still reference the
    /// binding's framebuffer and borrowed callback token.
    private func drainPendingFlip(_ binding: RenderOutputBinding) -> Bool {
        for _ in 0..<10 where binding.drm.pageFlipPending {
            var descriptor = pollfd(fd: drmDeviceFd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 10) > 0 {
                _ = DrmEventPump.dispatchIfReady(fd: drmDeviceFd)
            }
        }
        return !binding.drm.pageFlipPending
    }

    private func retireBinding(_ binding: RenderOutputBinding) -> Bool {
        guard drainPendingFlip(binding), binding.teardown() else { return false }
        retiredFlipTokens.append(binding.drm.flipToken)
        return true
    }

    /// Suspend the session on VT-switch-away: drop DRM master and cancel every
    /// output's in-flight presentation.
    public func pauseSession() {
        // Drain while master is still held. After dropMaster some drivers discard
        // the event, which previously left an unbalanced callback retain and an
        // ambiguous framebuffer lifetime.
        for binding in bindings.values { _ = drainPendingFlip(binding) }
        _ = DrmSession.dropMaster(fd: drmDeviceFd)
        for binding in bindings.values {
            let dropped = binding.drm.cancelPendingPresentation()
            binding.pendingSubmissionSerial = 0
            binding.pendingRenderSync = nil
            // The cancelled frames carry GPU-completion fence fds the caller owns;
            // close them so cancelling in-flight presentation on VT-switch-away does
            // not leak an fd per queued frame. Harmless today (the live present path
            // keeps these queues empty), correct once the frame queues are wired.
            for frame in dropped.rendered where frame.renderReadyFd >= 0 { close(frame.renderReadyFd) }
            for frame in dropped.mailbox where frame.renderReadyFd >= 0 { close(frame.renderReadyFd) }
        }
    }

    /// Resume the session on VT-switch-back: reacquire DRM master.
    public func resumeSession() {
        _ = DrmSession.setMaster(fd: drmDeviceFd)
    }

    // MARK: - Client surface content

    /// Import a committed client dmabuf as a sampleable texture under its IOSurface
    /// id, wrapping the core's import in the explicit-sync (syncobj) handshake.
    /// Multi-plane buffers are accepted when every plane shares the same dmabuf fd.
    @discardableResult
    public func registerSurfaceDmabuf(
        iosurfaceID: UInt64, fd: Int32, width: UInt32, height: UInt32,
        drmFormat: UInt32, modifier: UInt64, planes: [DmaBufPlane],
        acquire: DmaBufSyncPoint? = nil, release: DmaBufSyncPoint? = nil
    ) -> Bool {
        let acquireFenceFd: Int32
        if let acquire {
            guard let exported = exportSyncPoint(acquire) else { return false }
            acquireFenceFd = exported
        } else {
            acquireFenceFd = -1
        }
        let acquireFenceDiagnostic = DiagnosticSyncFile(duplicating: acquireFenceFd)
        let scanoutAcquireFenceFd = acquireFenceFd >= 0 ? dup(acquireFenceFd) : -1
        let previousRelease = pendingSurfaceReleaseSync[iosurfaceID]
        let ok = core.registerSurfaceTexture(
            iosurfaceID: iosurfaceID, fd: fd, width: width, height: height,
            drmFormat: drmFormat, modifier: modifier, planes: planes,
            contentGeneration: core.freshContentGeneration(),
            acquireFenceFd: acquireFenceFd)
        guard ok else {
            if scanoutAcquireFenceFd >= 0 { close(scanoutAcquireFenceFd) }
            if let release { signalSyncPoint(release) }
            return false
        }
        pendingClientAcquireFenceDiagnostics[iosurfaceID] = acquireFenceDiagnostic
        if let previousRelease {
            pendingSurfaceReleaseSync[iosurfaceID] = nil
            if isSurfaceScannedOut(iosurfaceID), let prior = clientScanoutBuffers[iosurfaceID] {
                suppressedCompositeRetireNotifications[iosurfaceID, default: 0] += 1
                prior.onDestroy = { [weak self] in
                    self?.signalSyncPoint(previousRelease)
                    self?.onSurfaceBufferRetired?(iosurfaceID)
                }
            } else {
                retiredCompositeReleaseSync[iosurfaceID, default: []].append(previousRelease)
            }
        }
        if let release { pendingSurfaceReleaseSync[iosurfaceID] = release }
        // Retain a KMS-importable copy of every opaque client buffer for potential
        // direct scanout. Eligibility can change without another client commit (for
        // example a static window becoming fullscreen), so retention cannot depend on
        // the candidate observed during this commit. Replacing the map entry drops our reference to the prior
        // buffer; if a pending scanout flip still holds it, it stays alive until the flip
        // drops it (then its deinit tears down the fb/handles/fds and fires any deferred
        // release) — so we never destroy a buffer the kernel is still scanning.
        releaseClientScanout(iosurfaceID)
        if isOpaqueScanoutFormat(drmFormat) {
            clientScanoutBuffers[iosurfaceID] = ClientScanoutBuffer.retain(
                deviceFd: drmDeviceFd, gemTable: gemHandleTable, fd: fd, width: width, height: height,
                format: drmFormat, modifier: modifier, planes: planes,
                acquireFenceFd: scanoutAcquireFenceFd)
            if clientScanoutBuffers[iosurfaceID] == nil, scanoutAcquireFenceFd >= 0 {
                close(scanoutAcquireFenceFd)
            }
        } else if scanoutAcquireFenceFd >= 0 {
            close(scanoutAcquireFenceFd)
        }
        return true
    }

    /// Drop our reference to a surface's retained client scanout buffer. It is NOT
    /// destroyed here: a buffer a pending scanout flip still retains stays alive (ARC)
    /// until the flip drops it, then its deinit runs the teardown. An unscanned buffer
    /// has no other reference, so it deinits (and tears down) immediately.
    private func releaseClientScanout(_ iosurfaceID: UInt64) {
        clientScanoutBuffers.removeValue(forKey: iosurfaceID)
    }

    /// Whether `iosurfaceID` is latched on, or in-flight to, some output's primary
    /// plane by direct scanout (so its buffer must not be released yet).
    private func isSurfaceScannedOut(_ iosurfaceID: UInt64) -> Bool {
        scanoutSurfaces.isScannedOut(iosurfaceID)
    }

    /// The KMS framebuffer for a client surface's retained scanout buffer, imported on
    /// demand and TEST_ONLY-validated against `drm`. Returns 0 when the surface has no
    /// retained buffer or the buffer can't be scanned out by this output.
    func clientScanoutFramebuffer(iosurfaceID: UInt64, validateWith drm: DrmOutput) -> UInt32 {
        guard let buffer = clientScanoutBuffers[iosurfaceID] else { return 0 }
        let fb = buffer.framebufferId()
        guard fb != 0, drm.testScanoutCommit(fbId: fb) else { return 0 }
        return fb
    }

    // MARK: - Direct scanout

    /// Try to present `outputID` by flipping a fullscreen client buffer directly onto the
    /// primary plane, with no composition. Succeeds only when the output is eligible (the
    /// pushed candidate evaluates to `.eligible`), the client buffer imports + TEST_ONLY-
    /// validates as a scannable framebuffer, and the atomic flip is accepted — retaining
    /// the client buffer for the flip's duration (so it outlives a map replacement). A
    /// VRR-capable output requests adaptive sync while a client scans out (M3). Any miss
    /// returns false and the core composites the output normally.
    public func tryDirectScanout(_ outputID: UInt64) -> Bool {
        guard let binding = bindings[outputID], !binding.drm.pageFlipPending else { return false }
        guard case .eligible(let iosurfaceID)? = evaluateScanout(outputID), iosurfaceID != 0 else {
            return false
        }
        // Only scan out a surface that uses explicit sync (a release syncobj is
        // registered for its current buffer). A scanned buffer's release must be held
        // until the flip replaces it; we can defer the syncobj release, but the
        // wl_buffer.release for an implicit-sync client is sent in the surface layer at
        // commit time regardless of scanout — so promoting an implicit-sync client
        // would let it reuse a still-scanned buffer and tear. Implicit clients composite.
        guard pendingSurfaceReleaseSync[iosurfaceID] != nil else { return false }
        let fb = clientScanoutFramebuffer(iosurfaceID: iosurfaceID, validateWith: binding.drm)
        guard fb != 0, let clientBuffer = clientScanoutBuffers[iosurfaceID] else {
            return false
        }
        // M3: adaptive sync follows direct-scanout eligibility.
        let vrr = binding.drm.requestedVrr(directScanoutEligible: true)
        let acquireFenceFd = clientBuffer.takeAcquireFenceFd()
        defer { if acquireFenceFd >= 0 { close(acquireFenceFd) } }
        let rc = binding.drm.commitScanout(
            retaining: clientBuffer, fbId: fb, requestedVrr: vrr, modeset: false,
            inFenceFd: acquireFenceFd,
            cursor: cursorCommitState(for: binding))
        guard rc == 0 else {
            return false
        }
        let atomicCommitAcceptedNs = rendererMonotonicNowNs()
        binding.pendingSubmissionSerial = 0
        binding.pendingRenderSync = nil
        pendingClientAcquireFenceDiagnostics[iosurfaceID] = nil
        core.discardPendingSurfaceAcquire(iosurfaceID: iosurfaceID)
        scanoutSurfaces.submitScanout(output: outputID, iosurfaceID: iosurfaceID)
        cursorPresentDirty.remove(outputID)
        onOutputSubmitted?(outputID, 0, atomicCommitAcceptedNs)
        return true
    }

    /// Upload a client SHM buffer as a renderer-native RGBA raster image.
    @discardableResult
    public func registerSurfaceShm(
        iosurfaceID: UInt64, pixels: [UInt8],
        width: UInt32, height: UInt32, drmFormat: UInt32, stride: UInt32
    ) -> Bool {
        let registered = core.registerSurfaceShm(
            iosurfaceID: iosurfaceID, pixels: pixels,
            width: width, height: height, drmFormat: drmFormat, stride: stride)
        if registered { pendingClientAcquireFenceDiagnostics[iosurfaceID] = nil }
        return registered
    }

    /// Drop a client surface's imported texture at surface teardown. Signals the
    /// surface's pending explicit-sync release first: with the surface gone no future
    /// commit will replace the buffer, so otherwise the client's release timeline
    /// point would never fire until full compositor shutdown.
    public func releaseSurfaceTexture(iosurfaceID: UInt64) {
        pendingClientAcquireFenceDiagnostics[iosurfaceID] = nil
        // If the surface's buffer is still on a plane, defer its release to the flip that
        // drops it (like a buffer replace) rather than firing while the kernel scans it —
        // the surface is gone so nothing else will re-trigger it, and the retained
        // buffer's `onDestroy` fires it when the flip rotates it out. Otherwise release
        // now. The tracker keeps listing it as scanned until that flip (correct — the
        // buffer is still latched); no more commits arrive for a torn-down surface.
        if isSurfaceScannedOut(iosurfaceID),
           let buffer = clientScanoutBuffers[iosurfaceID],
           let deferred = pendingSurfaceReleaseSync.removeValue(forKey: iosurfaceID) {
            suppressedCompositeRetireNotifications[iosurfaceID, default: 0] += 1
            buffer.onDestroy = { [weak self] in
                self?.signalSyncPoint(deferred)
                self?.onSurfaceBufferRetired?(iosurfaceID)
            }
        } else if let deferred = pendingSurfaceReleaseSync.removeValue(forKey: iosurfaceID) {
            retiredCompositeReleaseSync[iosurfaceID, default: []].append(deferred)
        }
        releaseClientScanout(iosurfaceID)
        core.releaseSurfaceTexture(iosurfaceID: iosurfaceID)
    }

    /// The importable (DRM fourcc, modifier) pairs advertised to dmabuf clients.
    public func dmabufSupportedFormats() -> [DmaBufFormatModifier] {
        core.dmabufSupportedFormats()
    }

    // MARK: - Screencopy

    /// Read back `outputID`'s composited frame as tightly-packed BGRA8888 (the wl_shm
    /// XRGB8888 byte order) for a screencopy capture. nil when the output has no frame
    /// yet or the readback fails. The screencopy block forces composition first so the
    /// accumulator holds the current content.
    public func captureOutputBGRA(outputID: UInt64) -> (pixels: [UInt8], width: Int, height: Int)? {
        core.captureOutputBGRA(outputID: outputID)
    }

    public func readSurfaceTextureBGRA(
        iosurfaceID: UInt32
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        core.readSurfaceTextureBGRA(iosurfaceID: UInt64(iosurfaceID))
    }

    /// Blit `outputID`'s composited frame directly into a client dmabuf render target
    /// (a screencopy dmabuf capture, no CPU round-trip). Returns false on any failure
    /// (no frame, unimportable buffer, non-render-target), so the caller can fall back.
    public func captureOutputToDmabuf(
        outputID: UInt64, fd: Int32, width: UInt32, height: UInt32,
        drmFormat: UInt32, modifier: UInt64, planes: [DmaBufPlane],
        sourceX: Int32 = 0, sourceY: Int32 = 0,
        sourceWidth: Int32 = 0, sourceHeight: Int32 = 0,
        overlayCursor: Bool = false
    ) -> Bool {
        let overlay = overlayCursor ? captureCursorOverlay(outputID: outputID) : nil
        return core.captureOutputToDmabuf(
            outputID: outputID, fd: fd, width: width, height: height,
            drmFormat: drmFormat, modifier: modifier, planes: planes,
            sourceX: sourceX, sourceY: sourceY,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, overlay: overlay)
    }

    private func captureCursorOverlay(outputID: UInt64) -> CaptureOverlay? {
        guard let binding = bindings[outputID], cursorImageWidth > 0, cursorImageHeight > 0,
              cursorPixels.count >= Int(cursorImageWidth * cursorImageHeight * 4)
        else { return nil }
        // Hardware cursor storage is little-endian ARGB8888 (BGRA bytes); Skia's
        // raster helper consumes premultiplied RGBA bytes.
        var rgba = cursorPixels
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgba.swapAt(index, index + 2)
        }
        let x = Int32(((cursorX - binding.logicalRect.x) * binding.fractionalScale).rounded())
            - cursorHotspotX
        let y = Int32(((cursorY - binding.logicalRect.y) * binding.fractionalScale).rounded())
            - cursorHotspotY
        return CaptureOverlay(
            rgbaPixels: rgba, width: Int32(cursorImageWidth), height: Int32(cursorImageHeight),
            x: x, y: y)
    }

    // MARK: - Snapshots

    @discardableResult
    public func registerSnapshot(textureHandle: UInt64, width: Float, height: Float) -> UInt64 {
        core.registerSnapshot(textureHandle: textureHandle, width: width, height: height)
    }

    public func releaseSnapshot(_ snapshotHandle: UInt64) {
        core.releaseSnapshot(snapshotHandle)
    }

    // MARK: - Explicit sync (DRM syncobj)

    /// Import a client DRM syncobj timeline fd into the renderer's DRM device.
    public func importSyncobjTimeline(fd: Int32) -> UInt32? {
        guard drmDeviceFd >= 0, fd >= 0 else { return nil }
        var handle: UInt32 = 0
        guard drmSyncobjFDToHandle(drmDeviceFd, fd, &handle) == 0, handle != 0 else { return nil }
        return handle
    }

    public func destroySyncobjTimeline(handle: UInt32) {
        if drmDeviceFd >= 0, handle != 0 {
            _ = drmSyncobjDestroy(drmDeviceFd, handle)
        }
    }

    /// Export a timeline point as a sync_file without waiting on the CPU. The
    /// Vulkan queue consumes that sync_file through an imported binary semaphore.
    private func exportSyncPoint(_ sync: DmaBufSyncPoint) -> Int32? {
        guard drmDeviceFd >= 0, sync.handle != 0 else { return nil }
        var temporary: UInt32 = 0
        guard drmSyncobjCreate(drmDeviceFd, 0, &temporary) == 0, temporary != 0 else { return nil }
        defer { _ = drmSyncobjDestroy(drmDeviceFd, temporary) }
        guard drmSyncobjTransfer(
            drmDeviceFd, temporary, 0, sync.handle, sync.point, 0) == 0
        else { return nil }
        var fd: Int32 = -1
        guard drmSyncobjExportSyncFile(drmDeviceFd, temporary, &fd) == 0, fd >= 0 else { return nil }
        return fd
    }

    private func signalSyncPoint(_ sync: DmaBufSyncPoint) {
        guard drmDeviceFd >= 0, sync.handle != 0 else { return }
        var handle = sync.handle
        var point = sync.point
        _ = drmSyncobjTimelineSignal(drmDeviceFd, &handle, &point, 1)
    }

    private func signalSurfaceRelease(iosurfaceID: UInt64) {
        if let release = pendingSurfaceReleaseSync.removeValue(forKey: iosurfaceID) {
            signalSyncPoint(release)
        }
    }

    private func signalRetiredCompositeRelease(iosurfaceID: UInt64) {
        guard var releases = retiredCompositeReleaseSync[iosurfaceID], !releases.isEmpty else { return }
        let release = releases.removeFirst()
        if releases.isEmpty { retiredCompositeReleaseSync[iosurfaceID] = nil }
        else { retiredCompositeReleaseSync[iosurfaceID] = releases }
        signalSyncPoint(release)
    }

    private func retiredCompositeBacking(iosurfaceID: UInt64) {
        signalRetiredCompositeRelease(iosurfaceID: iosurfaceID)
        if let suppressed = suppressedCompositeRetireNotifications[iosurfaceID], suppressed > 0 {
            if suppressed == 1 { suppressedCompositeRetireNotifications[iosurfaceID] = nil }
            else { suppressedCompositeRetireNotifications[iosurfaceID] = suppressed - 1 }
            return
        }
        onSurfaceBufferRetired?(iosurfaceID)
    }

    private func signalPendingSurfaceReleases() {
        let releases = pendingSurfaceReleaseSync.values
        pendingSurfaceReleaseSync.removeAll(keepingCapacity: true)
        for release in releases { signalSyncPoint(release) }
        let retired = retiredCompositeReleaseSync.values.flatMap { $0 }
        retiredCompositeReleaseSync.removeAll(keepingCapacity: true)
        for release in retired { signalSyncPoint(release) }
    }

    // MARK: - Teardown

    /// Tear down in GPU-lifetime order: the core drops its render resources
    /// (accumulators + registry + imported client images) → every binding's scanout
    /// ring (images + BOs + KMS fbs) → the core drops Graphite and then the device.
    /// Returns `false` when kernel presentation never retired. In that case the
    /// caller must keep this runtime alive until process exit: destroying Vulkan,
    /// GBM, or KMS resources which the kernel may still reference is unsafe, but
    /// returning promptly is required so the compositor can release its DRM
    /// session and seat.
    public func shutdown() -> Bool {
        logRendererDrm("shutdown: draining pending page flips")
        // The main reactor is no longer draining DRM readiness at this point. Give
        // an accepted non-blocking flip a bounded chance to complete before the
        // blocking disable commit; otherwise NVIDIA rejects the disable with
        // EBUSY and leaves the last framebuffer on screen after the exit keybind.
        for binding in bindings.values { _ = drainPendingFlip(binding) }
        guard !bindings.values.contains(where: { $0.drm.pageFlipPending }) else {
            logRendererDrm(
                "shutdown: page flip did not retire; abandoning GPU/KMS resources so the DRM session can close"
            )
            return false
        }
        // Queue-idle makes every semaphore safe to destroy, including submits whose
        // fence export or atomic commit failed and therefore never reached a flip.
        core.waitForGpuIdle()
        for binding in bindings.values {
            guard retireBinding(binding) else {
                logRendererDrm("shutdown: scanout disable failed; preserving GPU/KMS resources")
                return false
            }
        }
        bindings.removeAll()
        logRendererDrm("shutdown: scanout disabled")
        core.shutdownRenderResources()
        pendingClientAcquireFenceDiagnostics.removeAll()
        primaryPlaneFormats.removeAll()
        scanoutCandidates.removeAll()
        lastScanoutDecision.removeAll()
        cursorPresentDirty.removeAll()
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

private func logScanout(_ message: String) {
    let line = "scanout: \(message)\n"
    line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
}
