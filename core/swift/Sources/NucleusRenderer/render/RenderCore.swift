// The platform-agnostic render core: the Vulkan instance/device, the Graphite
// context + `FrameDriver`, the authoritative `RetainedTreeStore`, client
// surface/texture registration, and per-output frame recording into a borrowed
// GPU image. It owns nothing platform-specific — no DRM/KMS, no GBM, no swapchain.
// Presentation is a `PresentationBackend` (Linux DRM/KMS scanout, Android Vulkan
// swapchain); `renderReady(backend:)` drives the loop by asking the backend to
// acquire the image to record into and to present what was recorded.
//
// LIFETIME INVARIANT (mirrors the GPU teardown contract): scanout/swapchain
// surfaces are transient — the backend hands a borrowed image to `recordFrame`,
// which wraps a Graphite surface over it for exactly one frame and drops it before
// returning, so no long-lived Skia surface outlives its backing image. The only
// long-lived GPU objects the core owns are the frame driver's accumulators/
// registry and the imported client-surface images. `shutdownRenderResources()`
// drops those before device teardown, and `teardownDevice()` explicitly releases
// Graphite before dropping the borrowed Vulkan device/instance.

import NucleusSkiaGraphiteBridge
import VulkanC
import Vulkan

private final class ClientAcquireSemaphore {
    let semaphore: VkSemaphore
    private let device: VkDevice
    private let dispatch: VK.DeviceDispatch

    init?(device: VkDevice, dispatch: VK.DeviceDispatch, consumingSyncFd fd: Int32) {
        guard fd >= 0, let create = dispatch.vkCreateSemaphore,
              let importFd = dispatch.vkImportSemaphoreFdKHR else {
            if fd >= 0 { close(fd) }
            return nil
        }
        var info = VkSemaphoreCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var created: VkSemaphore?
        guard create(device, &info, nil, &created) == VK_SUCCESS, let created else {
            close(fd)
            return nil
        }
        var importInfo = VkImportSemaphoreFdInfoKHR()
        importInfo.sType = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR
        importInfo.semaphore = created
        importInfo.flags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT.rawValue
        importInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT
        importInfo.fd = fd
        guard importFd(device, &importInfo) == VK_SUCCESS else {
            dispatch.vkDestroySemaphore?(device, created, nil)
            close(fd)
            return nil
        }
        self.device = device
        self.dispatch = dispatch
        self.semaphore = created
    }

    deinit { dispatch.vkDestroySemaphore?(device, semaphore, nil) }
}

struct OutputPresentationLedger {
    struct Entry: Equatable {
        var treeRevision: UInt64 = 0
        var lockGeneration: UInt64 = 0
    }

    private(set) var entries: [UInt64: Entry] = [:]

    mutating func attach(_ outputID: UInt64) { entries[outputID] = Entry() }
    mutating func detach(_ outputID: UInt64) { entries[outputID] = nil }

    func needsTreeRevision(_ revision: UInt64, outputID: UInt64) -> Bool {
        entries[outputID, default: Entry()].treeRevision < revision
    }

    func needsLockGeneration(_ generation: UInt64, outputID: UInt64) -> Bool {
        entries[outputID, default: Entry()].lockGeneration < generation
    }

    mutating func acknowledge(_ outputID: UInt64, treeRevision: UInt64, lockGeneration: UInt64) {
        entries[outputID] = Entry(treeRevision: treeRevision, lockGeneration: lockGeneration)
    }

    func allPresented(_ outputIDs: [UInt64], treeRevision: UInt64) -> Bool {
        outputIDs.allSatisfy { !needsTreeRevision(treeRevision, outputID: $0) }
    }

    mutating func removeAll() { entries.removeAll() }
}
import NucleusRenderModel

@_spi(NucleusPlatform)
public struct CaptureOverlay: Sendable {
    public var rgbaPixels: [UInt8]
    public var width: Int32
    public var height: Int32
    public var x: Int32
    public var y: Int32

    public init(rgbaPixels: [UInt8], width: Int32, height: Int32, x: Int32, y: Int32) {
        self.rgbaPixels = rgbaPixels
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }
}
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

struct PendingShmUpload: Equatable {
    var pixels: [UInt8]
    var width: Int32
    var height: Int32
    var generation: UInt64
}

/// Last-writer-wins queue keyed by stable client texture id. It bounds queued
/// memory to one converted buffer per surface while the renderer is busy.
struct PendingShmUploadQueue {
    private var entries: [UInt64: PendingShmUpload] = [:]
    private(set) var byteCount: UInt64 = 0
    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    mutating func enqueue(_ upload: PendingShmUpload, for id: UInt64) -> Bool {
        let replaced = entries[id] != nil
        if let old = entries[id] { byteCount &-= UInt64(old.pixels.count) }
        entries[id] = upload
        byteCount &+= UInt64(upload.pixels.count)
        return replaced
    }

    mutating func drain() -> [UInt64: PendingShmUpload] {
        let result = entries
        entries.removeAll(keepingCapacity: true)
        byteCount = 0
        return result
    }

    mutating func remove(_ id: UInt64) -> PendingShmUpload? {
        guard let removed = entries.removeValue(forKey: id) else { return nil }
        byteCount &-= UInt64(removed.pixels.count)
        return removed
    }

    mutating func removeAll() {
        entries.removeAll()
        byteCount = 0
    }
}

/// The agnostic render core. Constructed once at bring-up (no platform fd); a
/// `PresentationBackend` is supplied per render pass. `store` is the shared
/// retained tree the layers commit sink writes into. `@MainActor`: the render
/// path runs on the main-loop thread (the layers commit sink and retained store
/// are already main-actor-isolated).
@MainActor
public final class RenderCore {
    nonisolated static func shouldRenderOutput(
        hasPendingDamage: Bool, forced: Bool, wantsPresent: Bool, needsInitialFrame: Bool
    ) -> Bool {
        hasPendingDamage || forced || wantsPresent || needsInitialFrame
    }

    /// The authoritative retained tree; the commit sink folds transactions in.
    public let store: RetainedTreeStore

    // Vulkan ownership (boxed noncopyable owners kept alive; their Copyable
    // handles/dispatch are copied out for per-frame use).
    private var instanceLifetime: VulkanInstanceLifetime?
    private var deviceBox: DeviceOwner?
    public let instanceHandle: VkInstance
    public let physicalDevice: VkPhysicalDevice
    public let instanceDispatch: VK.InstanceDispatch
    public let deviceHandle: VkDevice
    public let deviceDispatch: VK.DeviceDispatch
    public let graphicsFamily: UInt32
    /// The graphics+present queue (borrowed from the device). A presentation backend
    /// that shares this device (the Android swapchain presenter) submits + presents
    /// on it.
    public let graphicsQueue: VkQueue

    private var context: nucleus.skia.GraphiteContext
    private var frameDriver: FrameDriver?

    // Per-output presentation geometry (the agnostic `RenderTarget` the FramePlan
    // walk is parameterized by), keyed by output id. The backend registers each
    // output's geometry via `attachOutputGeometry`; `recordFrame` looks it up.
    private var outputTargets: [UInt64: RenderTarget] = [:]
    private var outputsNeedingInitialFrame: Set<UInt64> = []
    private var outputPresentationLedger = OutputPresentationLedger()
    private var frameSerial: UInt64 = 0
    public private(set) var lastSubmittedSerial: UInt64 = 0
    @_spi(NucleusPlatform) public private(set) var lastFrameTelemetry = RenderFrameTelemetry()
    @_spi(NucleusPlatform) public private(set) var lastFrameAcquiredSurfaceIDs: [UInt64] = []
    private var pendingFrameTelemetry: [RenderFrameTelemetry] = []
    private let telemetryClock = ContinuousClock()
    private var lastFrameRenderStarted: ContinuousClock.Instant?
    private var clientCommitInstants: [UInt64: ContinuousClock.Instant] = [:]
    private var lastFrameReferencedCommitInstants: [UInt64: ContinuousClock.Instant] = [:]
    private var presentedCommitsAwaitingRevisionAck: [UInt64: ContinuousClock.Instant] = [:]

    // Imported client-surface dmabuf images, keyed by IOSurface id. The texture
    // registry wraps these as sampleable Graphite images but does NOT own the
    // backing `VkImage` — the box keeps it alive while the registry entry lives,
    // released on content swap / surface destroy / shutdown (before the Graphite
    // context, per the GPU-lifetime invariant).
    private var importedSurfaceImages: [UInt64: VkOwnedImageBox] = [:]
    private var retiredSurfaceImages: [(serial: UInt64, image: VkOwnedImageBox, releaseID: UInt64)] = []
    private var pendingClientAcquireSemaphores: [UInt64: ClientAcquireSemaphore] = [:]
    private var retiredClientAcquireSemaphores: [(serial: UInt64, semaphore: ClientAcquireSemaphore)] = []
    private var pendingShmUploads = PendingShmUploadQueue()
    private var clientUploadTextures: [UInt64: nucleus.skia.UploadTexture] = [:]
    private var retiredClientUploadTextures: [(serial: UInt64, texture: nucleus.skia.UploadTexture)] = []
    public struct ClientUploadStats: Sendable, Equatable {
        public var enqueued: UInt64 = 0
        public var coalesced: UInt64 = 0
        public var uploaded: UInt64 = 0
        public var failed: UInt64 = 0
        public var pendingBytes: UInt64 = 0
    }
    public private(set) var clientUploadStats = ClientUploadStats()
    private var startupFrameDiagnosticsRemaining = 12
    private let sampleableDmaBufFormats: [DmaBufFormatModifier]
    private var nextSurfaceId: UInt32 = 1
    private var nextContentGeneration: UInt64 = 1

    // Snapshot registry: refcounted snapshot handles over the texture registry.
    private let snapshots = SwiftResourceHost.shared.snapshots

    /// Hook the presentation backend installs so the core can tell it a client
    /// surface's previous backing is no longer referenced (the backend signals the
    /// buffer's release syncobj). No-op when no backend uses release sync (Android).
    public var onSurfaceReleaseSync: ((UInt64) -> Void)?

    /// Session-lock composition, per output. `nil` is the normal unlocked path. When
    /// non-nil the compositor is locked and `recordFrame` composites only the listed
    /// lock-surface contexts for the output over the opaque ground; an absent or empty
    /// entry blanks that output entirely. This is the single scanout choke point that
    /// enforces the ext-session-lock `locked` invariant — no unlocked pixel can reach
    /// glass regardless of which scene authority authored it (see `PresentationWalk`).
    /// Set through `setLockComposition` by the composition root each frame from the
    /// authoritative window model.
    public private(set) var lockComposition: [UInt64: Set<ContextID>]?

    /// Set when `lockComposition` last changed and a forced redraw has not yet
    /// presented. A lock beginning need not damage the retained tree (non-lock windows
    /// stay hosted; the blank is a composition-time filter), so the damage gate alone
    /// would leave stale unlocked content on screen. This forces the transition frame.
    private var lockCompositionGeneration: UInt64 = 0

    /// Publish the session-lock composition. A change forces a redraw; while locked,
    /// `renderReady` also redraws every ready output each pass so the blank appears
    /// immediately and stays up regardless of tree damage.
    public func setLockComposition(_ value: [UInt64: Set<ContextID>]?) {
        if value != lockComposition {
            lockComposition = value
            lockCompositionGeneration &+= 1
            if lockCompositionGeneration == 0 { lockCompositionGeneration = 1 }
        }
    }

    /// Allocate a fresh non-zero IOSurface id for a new client surface.
    public func allocSurfaceId() -> UInt32 {
        let id = nextSurfaceId
        nextSurfaceId &+= 1
        if nextSurfaceId == 0 { nextSurfaceId = 1 }
        return id
    }

    private func nextGeneration() -> UInt64 {
        let g = nextContentGeneration
        nextContentGeneration &+= 1
        return g
    }

    /// Bring up the agnostic render core: the Vulkan instance/device, the Graphite
    /// context + frame driver, and the shared retained tree. No platform fd — the
    /// presentation backend owns the display device. Returns nil when the GPU stack
    /// is unavailable.
    public static func create(
        applicationName: String,
        presentation: VkRequirements.PresentationMode = .platformDefault
    ) -> RenderCore? {
        guard let bootstrap = VulkanBootstrap.create(
            applicationName: applicationName, presentation: presentation)
        else { return nil }
        return create(bootstrap: bootstrap, qualification: .none)
    }

    public static func create(
        bootstrap: VulkanBootstrap,
        qualification: VulkanPresentationQualification
    ) -> RenderCore? {
        guard !bootstrap.finalized else { return nil }
        let contract = bootstrap.contract
        guard let instanceHandle = bootstrap.instanceLifetime.owner?.handle,
              let instanceDispatch = bootstrap.instanceLifetime.owner?.dispatch
        else { return nil }
        let requiredSurface: VkSurfaceKHR?
        let probe: ((VkInstance, VkPhysicalDevice, UInt32) -> Bool)?
        switch qualification {
        case .none:
            requiredSurface = nil; probe = nil
        case .platformProbe(let body):
            requiredSurface = nil
            probe = { instance, device, family in
                body(VulkanInstanceHandle(instance), VulkanPhysicalDeviceHandle(device), family)
            }
        case .surface(let surface):
            guard surface.instance == instanceHandle else { return nil }
            requiredSurface = surface.handle; probe = nil
        }
        guard let selection = DeviceOwner.selectPhysicalDevice(
            instance: instanceHandle, dispatch: instanceDispatch, contract: contract,
            requiredPresentationSurface: requiredSurface,
            queueFamilyPresentationSupport: probe
        ) else { return nil }
        guard let device = DeviceOwner.create(
            selection: selection, instanceDispatch: instanceDispatch,
            contract: contract
        ) else { return nil }
        guard let queue = device.queue(family: selection.graphicsQueueFamily) else {
            return nil
        }

        // Build the Graphite context. The device-extension pointer is only needed
        // for the make call, so create the context inside the cstring scope and
        // copy the (value-typed) context out.
        let context: nucleus.skia.GraphiteContext = withCStringArray(
            contract.deviceExtensions
        ) { extPtr, extCount in
            var ctxDesc = nucleus.skia.VulkanContextDescriptor()
            ctxDesc.instance = UnsafeMutableRawPointer(instanceHandle)
            ctxDesc.physicalDevice = UnsafeMutableRawPointer(selection.physicalDevice)
            ctxDesc.device = UnsafeMutableRawPointer(device.handle)
            ctxDesc.queue = UnsafeMutableRawPointer(queue)
            ctxDesc.graphicsQueueIndex = selection.graphicsQueueFamily
            ctxDesc.maxApiVersion = contract.minimumApiVersion.raw
            ctxDesc.deviceExtensions = extPtr
            ctxDesc.deviceExtensionCount = extCount
            return nucleus.skia.makeGraphiteVulkanContext(ctxDesc)
        }
        guard context.isValid() else { return nil }
        guard let driver = FrameDriver(context: context) else { return nil }
        bootstrap.finalized = true
        _ = queue  // consumed only to build the context above

        return RenderCore(
            instanceLifetime: bootstrap.instanceLifetime, device: consume device, queue: queue,
            physicalDevice: selection.physicalDevice, graphicsFamily: selection.graphicsQueueFamily,
            context: context, driver: driver)
    }

    private init(
        instanceLifetime: VulkanInstanceLifetime, device: consuming DeviceOwner, queue: VkQueue,
        physicalDevice: VkPhysicalDevice, graphicsFamily: UInt32,
        context: nucleus.skia.GraphiteContext, driver: FrameDriver
    ) {
        // Copy the Copyable handles/dispatch out (borrow) before boxing the owners.
        guard let ownedInstanceHandle = instanceLifetime.owner?.handle,
              let ownedInstanceDispatch = instanceLifetime.owner?.dispatch
        else {
            preconditionFailure("finalized Vulkan bootstrap lost its instance")
        }
        self.instanceHandle = ownedInstanceHandle
        self.physicalDevice = physicalDevice
        self.instanceDispatch = ownedInstanceDispatch
        self.deviceHandle = device.handle
        self.deviceDispatch = device.dispatch
        self.graphicsFamily = graphicsFamily
        self.graphicsQueue = queue
        self.context = context
        self.frameDriver = driver
        self.sampleableDmaBufFormats = querySampleableDmaBufFormats(
            physicalDevice: physicalDevice, instanceDispatch: ownedInstanceDispatch)
        // Bind to the process-global authoritative tree the layers commit sink
        // feeds, so committed transactions and the per-frame read share one tree.
        self.store = RetainedTreeStore.shared
        self.instanceLifetime = instanceLifetime
        self.deviceBox = consume device
        // Evict the decoded-image cache entry when its source is released from the
        // shared store. Weak so the process-global store does not retain the driver.
        SwiftResourceHost.shared.images.onEvict = { [weak driver] handle in
            driver?.evictDecodedImage(handle)
        }
        SwiftResourceHost.shared.runtimeEffects.onEvict = { [weak driver] handle in
            driver?.evictCompiledEffect(handle)
        }
    }

    public func createSurface(_ factory: VulkanSurfaceFactory) -> VulkanSurface? {
        guard let instanceLifetime,
              let token = factory(VulkanInstanceHandle(instanceHandle))
        else { return nil }
        return VulkanSurface(
            lifetime: instanceLifetime, instance: instanceHandle, dispatch: instanceDispatch,
            handle: token.vkSurface)
    }

    // MARK: - Output geometry

    /// Register (or replace) one output's presentation geometry — the agnostic
    /// `RenderTarget` the FramePlan walk is parameterized by. The presentation
    /// backend calls this when it attaches an output; `recordFrame` looks it up.
    public func attachOutputGeometry(
        outputID: UInt64,
        logicalX: Double, logicalY: Double, logicalWidth: Double, logicalHeight: Double,
        pixelWidth: UInt32, pixelHeight: UInt32, fractionalScale: Double
    ) {
        let metadata = OutputTargetMetadata(
            outputId: outputID,
            logicalRect: LogicalRect(x: logicalX, y: logicalY, width: logicalWidth, height: logicalHeight),
            pixelSize: PixelSize(width: pixelWidth, height: pixelHeight),
            fractionalScale: fractionalScale)
        outputTargets[outputID] = RenderTargetAssembly.make(metadata)
        outputsNeedingInitialFrame.insert(outputID)
        outputPresentationLedger.attach(outputID)
    }

    /// Drop an output's geometry (the backend detached it) and its persistent GPU
    /// accumulator, so a removed output leaks neither.
    public func detachOutputGeometry(outputID: UInt64) {
        outputTargets[outputID] = nil
        outputsNeedingInitialFrame.remove(outputID)
        outputPresentationLedger.detach(outputID)
        frameDriver?.dropAccumulator(output: outputID)
    }

    // MARK: - The render loop

    /// Vulkan image usage flags for the borrowed frame target, by kind. Both kinds
    /// expose `VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT` so the Graphite render-target
    /// wrap succeeds.
    private func usageFlags(for kind: FrameTargetKind) -> VK.ImageUsageFlags {
        switch kind {
        case .drmScanout: return DmaBufImageDescriptor.scanoutUsage
        case .swapchainColor: return [.colorAttachmentBit, .transferDstBit]
        }
    }

    /// Record one frame for `outputID` into the backend-acquired `target` image:
    /// wrap a transient Graphite surface over it, composite the retained tree, and
    /// submit. Returns true when a frame was presented (the backend then scans it
    /// out). Does not flip/present — that is the backend's `present`.
    public func recordFrame(outputID: UInt64, target: AcquiredFrameTarget) -> Bool {
        let renderStarted = telemetryClock.now
        lastFrameRenderStarted = renderStarted
        lastFrameAcquiredSurfaceIDs.removeAll(keepingCapacity: true)
        guard let driver = frameDriver, let renderTarget = outputTargets[outputID] else { return false }
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
            usageFlags: usageFlags(for: target.kind), queueFamilyIndex: target.queueFamily,
            hasAlpha: target.hasAlpha)
        let surface = ScanoutSurface.wrap(recorder: driver.recorder, params: params)
        guard surface.isValid() else { return false }
        let targetWrapNs = elapsedNanoseconds(phaseStarted, telemetryClock.now)

        // The swapchain path submits for presentation (WSI acquire/present
        // semaphores + PRESENT_SRC transition); the DRM scanout path submits plain.
        let present: FrameDriver.PresentSubmit? = target.kind == .swapchainColor
            ? FrameDriver.PresentSubmit(
                waitSemaphore: target.waitSemaphore,
                signalSemaphore: target.signalSemaphore,
                queueFamily: target.queueFamily)
            : nil
        let drmSubmit: FrameDriver.DrmSubmit? = target.kind == .drmScanout
            ? target.signalSemaphore.map { FrameDriver.DrmSubmit(signalSemaphore: $0) }
            : nil

        phaseStarted = telemetryClock.now
        let tree = store.snapshot()
        let treeSnapshotNs = elapsedNanoseconds(phaseStarted, telemetryClock.now)
        // Session-lock choke point: while locked, restrict this output's composition
        // to its allowed lock-surface contexts (empty/absent → fully blanked). nil is
        // the normal, unrestricted composition.
        let lockContexts: Set<ContextID>? = lockComposition.map { $0[outputID] ?? [] }
        let result = driver.renderFrame(
            tree: tree, target: renderTarget, frame: frame, scanout: surface,
            present: present,
            drmSubmit: drmSubmit,
            acquireWaitSemaphores: pendingClientAcquireSemaphores.mapValues(\.semaphore),
            lockContexts: lockContexts,
            resolvePaintContent: { SwiftResourceHost.shared.paintContents.content($0) },
            resolvePaintImage: { handle in
                guard let source = SwiftResourceHost.shared.images.source(handle) else { return nil }
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
                    lockGeneration: targetLockGeneration)
                outputsNeedingInitialFrame.remove(outputID)
                any = true
                continue
            }
            let acquireStarted = telemetryClock.now
            guard let target = backend.acquireTarget(outputID) else { continue }
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
                    lockGeneration: targetLockGeneration)
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

    // MARK: - Screencopy / screenshot readback

    /// Read `outputID`'s composited accumulator back into host BGRA8888 pixels (the
    /// wl_shm XRGB8888 / DRM XR24 byte order, tightly packed), with its width/height.
    /// Returns nil when the output has no accumulator yet or the GPU readback fails.
    /// The caller must have forced a composite frame (the screencopy block does this),
    /// so the accumulator holds the current output content. The readback is synchronous.
    public func captureOutputBGRA(outputID: UInt64) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let driver = frameDriver, let accumulator = driver.accumulator(for: outputID) else { return nil }
        let surface = accumulator.surface
        let w = Int(surface.width())
        let h = Int(surface.height())
        guard w > 0, h > 0 else { return nil }
        guard let pixels = Screenshot.readback(context: context, surface: surface, format: .bgra8888) else {
            return nil
        }
        return (pixels, w, h)
    }

    /// Read a registered client texture through a compositor-owned render target.
    /// Imported dmabuf images are GPU-backed, so drawing through the active recorder
    /// gives Graphite the context required for a reliable synchronous readback.
    public func readSurfaceTextureBGRA(
        iosurfaceID: UInt64
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let driver = frameDriver,
              let image = driver.registry.resolve(iosurfaceID), image.isValid()
        else { return nil }
        let width = image.width()
        let height = image.height()
        guard width > 0, height > 0 else { return nil }
        let surface = driver.recorder.makeOffscreenSurface(width, height)
        guard surface.isValid() else { return nil }
        var source = nucleus.skia.RectF()
        source.width = Float(width); source.height = Float(height)
        var paint = nucleus.skia.Paint()
        paint.blend = nucleus.skia.BlendMode.src
        surface.getCanvas().drawImageRect(image, source, source, paint)
        let recording = driver.recorder.snapRecording()
        guard recording.isValid(), context.submit(recording) == nucleus.skia.Status.ok,
              let pixels = Screenshot.readback(context: context, surface: surface, format: .bgra8888)
        else { return nil }
        return (pixels, Int(width), Int(height))
    }

    /// Blit `outputID`'s composited accumulator directly into a client dmabuf render
    /// target (a screencopy dmabuf capture — no CPU round-trip). Imports the client
    /// dmabuf as a color-attachment image, wraps it as a Graphite render surface, draws
    /// the accumulator into it (`BlendMode.src`), and submits synchronously so the
    /// buffer is ready on return. Returns false when the output has no frame, the
    /// import/wrap fails, or the buffer can't be a render target. `fd`/`planes` are
    /// borrowed — `importDmaBufImage` dups internally.
    @_spi(NucleusPlatform)
    public func captureOutputToDmabuf(
        outputID: UInt64,
        fd: Int32, width: UInt32, height: UInt32, drmFormat: UInt32, modifier: UInt64,
        planes: [DmaBufPlane], sourceX: Int32 = 0, sourceY: Int32 = 0,
        sourceWidth: Int32 = 0, sourceHeight: Int32 = 0,
        overlay: CaptureOverlay? = nil
    ) -> Bool {
        guard let driver = frameDriver, let accumulator = driver.accumulator(for: outputID) else { return false }
        let descriptor = DmaBufImageDescriptor(
            fd: fd, width: width, height: height, drmFormat: drmFormat, modifier: modifier,
            planes: planes, usage: DmaBufImageDescriptor.scanoutUsage)
        guard let imported = importDmaBufImage(
            device: deviceHandle, dispatch: deviceDispatch, descriptor: descriptor
        ) else { return false }
        // Wrap + blit + synchronous submit while `imported` is alive; the explicit
        // consume below frees the VkImage only after the GPU is done with it (submit
        // syncs to CPU), and after the transient surface has dropped.
        let ok = blitAccumulatorIntoImage(
            accumulator, image: imported.handle, recorder: driver.recorder,
            width: Int32(width), height: Int32(height), format: vulkanFormatForDrm(drmFormat),
            sourceX: sourceX, sourceY: sourceY,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, overlay: overlay)
        _ = consume imported
        return ok
    }

    private func blitAccumulatorIntoImage(
        _ accumulator: OutputAccumulator, image: VkImage, recorder: nucleus.skia.Recorder,
        width: Int32, height: Int32, format: VkFormat,
        sourceX: Int32, sourceY: Int32, sourceWidth: Int32, sourceHeight: Int32,
        overlay: CaptureOverlay?
    ) -> Bool {
        let params = ScanoutImageParams(
            image: image, memory: nil, allocSize: 0,
            width: width, height: height, format: format,
            tiling: VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: DmaBufImageDescriptor.scanoutUsage, queueFamilyIndex: graphicsFamily,
            hasAlpha: false)
        let surface = ScanoutSurface.wrap(recorder: recorder, params: params)
        var source: nucleus.skia.RectF?
        if sourceWidth > 0, sourceHeight > 0 {
            var rect = nucleus.skia.RectF()
            rect.x = Float(sourceX); rect.y = Float(sourceY)
            rect.width = Float(sourceWidth); rect.height = Float(sourceHeight)
            source = rect
        }
        guard surface.isValid(), accumulator.present(onto: surface, source: source) else { return false }
        if let overlay,
           overlay.width > 0, overlay.height > 0,
           overlay.rgbaPixels.count >= Int(overlay.width) * Int(overlay.height) * 4 {
            let image = overlay.rgbaPixels.withUnsafeBufferPointer {
                nucleus.skia.makeRasterImageRGBA(
                    overlay.width, overlay.height, $0.baseAddress, $0.count)
            }
            if image.isValid() {
                var src = nucleus.skia.RectF()
                src.width = Float(overlay.width); src.height = Float(overlay.height)
                var dst = src
                dst.x = Float(overlay.x - sourceX)
                dst.y = Float(overlay.y - sourceY)
                var paint = nucleus.skia.Paint()
                paint.blend = nucleus.skia.BlendMode.srcOver
                surface.getCanvas().drawImageRect(image, src, dst, paint)
            }
        }
        let recording = recorder.snapRecording()
        return recording.isValid() && context.submit(recording) == nucleus.skia.Status.ok
    }

    // MARK: - Client surface content

    /// Import a committed client dmabuf as a sampleable texture under its IOSurface
    /// id (no syncobj — the backend wraps explicit-sync around this). The dmabuf is
    /// imported on the renderer's own Vulkan device, wrapped as a Graphite image,
    /// and held for the registry entry's lifetime. `fd` is dup'd internally.
    /// Replaces any prior backing for `iosurfaceID`. Returns false on failure.
    @discardableResult
    public func registerSurfaceTexture(
        iosurfaceID: UInt64, fd: Int32, width: UInt32, height: UInt32,
        drmFormat: UInt32, modifier: UInt64, planes: [DmaBufPlane],
        contentGeneration: UInt64, acquireFenceFd: Int32 = -1
    ) -> Bool {
        let commitInstant = telemetryClock.now
        func fail(_ stage: String) -> Bool {
            #if canImport(Glibc)
            let line = "surface-texture: failed stage=\(stage) id=\(iosurfaceID) size=\(width)x\(height) format=\(drmFormat) modifier=\(modifier) planes=\(planes.count)\n"
            line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
            #endif
            return false
        }
        guard iosurfaceID != 0 else {
            if acquireFenceFd >= 0 { close(acquireFenceFd) }
            return fail("invalid-id")
        }
        let acquireSemaphore: ClientAcquireSemaphore?
        if acquireFenceFd >= 0 {
            guard let importedSemaphore = ClientAcquireSemaphore(
                device: deviceHandle, dispatch: deviceDispatch,
                consumingSyncFd: acquireFenceFd)
            else { return fail("acquire-semaphore-import") }
            acquireSemaphore = importedSemaphore
        } else {
            acquireSemaphore = nil
        }
        guard let driver = frameDriver else { return fail("missing-frame-driver") }
        guard !planes.isEmpty else { return fail("missing-planes") }
        var importedFdBySource: [Int32: Int32] = [:]
        var importPlanes: [DmaBufPlane] = []
        importPlanes.reserveCapacity(planes.count)
        for plane in planes {
            let sourceFd = plane.fd >= 0 ? plane.fd : fd
            if importedFdBySource[sourceFd] == nil {
                let imported = dup(sourceFd)
                guard imported >= 0 else {
                    for imported in importedFdBySource.values { close(imported) }
                    return fail("dup-fd")
                }
                importedFdBySource[sourceFd] = imported
            }
            importPlanes.append(DmaBufPlane(
                fd: importedFdBySource[sourceFd] ?? -1,
                offset: plane.offset, rowPitch: plane.rowPitch))
        }
        guard let importFd = importPlanes.first?.fd, importFd >= 0 else {
            for imported in importedFdBySource.values { close(imported) }
            return fail("missing-import-fd")
        }

        let descriptor = DmaBufImageDescriptor(
            fd: importFd, width: width, height: height, drmFormat: drmFormat, modifier: modifier,
            planes: importPlanes, usage: DmaBufImageDescriptor.sampledUsage)
        guard let imported = importDmaBufImage(
            device: deviceHandle, dispatch: deviceDispatch, descriptor: descriptor
        ) else {
            return fail("vulkan-import")
        }

        let params = ScanoutImageParams(
            image: imported.handle, memory: nil, allocSize: 0,
            width: Int32(width), height: Int32(height), format: vulkanFormatForDrm(drmFormat),
            tiling: VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: DmaBufImageDescriptor.sampledUsage, queueFamilyIndex: graphicsFamily,
            hasAlpha: true)
        guard let image = driver.registry.wrapBackendImage(
            recorder: driver.recorder, descriptor: ScanoutSurface.descriptor(params)
        ) else {
            // The imported VkImage drops here (VkOwned deinit) — wrap failed.
            return fail("graphite-wrap")
        }

        // Hold the backing alive for the registry entry. A replaced backing stays
        // retired until the asynchronous presentation backend reports completion.
        if let old = importedSurfaceImages[iosurfaceID] {
            retiredSurfaceImages.append((lastSubmittedSerial, old, iosurfaceID))
        }
        importedSurfaceImages[iosurfaceID] = VkOwnedImageBox(consuming: imported)
        driver.registry.register(
            handle: iosurfaceID, image: image,
            width: Int32(width), height: Int32(height), contentRevision: contentGeneration)
        pendingClientAcquireSemaphores[iosurfaceID] = acquireSemaphore
        _ = pendingShmUploads.remove(iosurfaceID)
        clientUploadStats.pendingBytes = pendingShmUploads.byteCount
        if let old = clientUploadTextures.removeValue(forKey: iosurfaceID) {
            retiredClientUploadTextures.append((lastSubmittedSerial, old))
        }
        clientCommitInstants[iosurfaceID] = commitInstant
        return true
    }

    /// The content generation for a fresh client upload.
    public func freshContentGeneration() -> UInt64 { nextGeneration() }

    /// The renderer device's importable sampled dmabuf format/modifier table.
    public func dmabufSupportedFormats() -> [DmaBufFormatModifier] {
        sampleableDmaBufFormats
    }

    /// Probe the complete Vulkan external-memory path without registering client
    /// content. The caller retains its fds; duplicates are consumed by the probe.
    public func canImportSurfaceDmaBuf(
        fd: Int32,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [DmaBufPlane]
    ) -> Bool {
        guard width > 0, height > 0, !planes.isEmpty,
            sampleableDmaBufFormats.contains(
                DmaBufFormatModifier(format: drmFormat, modifier: modifier))
        else { return false }

        var importedFdBySource: [Int32: Int32] = [:]
        var importPlanes: [DmaBufPlane] = []
        importPlanes.reserveCapacity(planes.count)
        for plane in planes {
            let sourceFd = plane.fd >= 0 ? plane.fd : fd
            if importedFdBySource[sourceFd] == nil {
                let imported = dup(sourceFd)
                guard imported >= 0 else {
                    for duplicate in importedFdBySource.values { close(duplicate) }
                    return false
                }
                importedFdBySource[sourceFd] = imported
            }
            importPlanes.append(DmaBufPlane(
                fd: importedFdBySource[sourceFd] ?? -1,
                offset: plane.offset,
                rowPitch: plane.rowPitch))
        }
        guard let importFd = importPlanes.first?.fd, importFd >= 0 else {
            for duplicate in importedFdBySource.values { close(duplicate) }
            return false
        }
        let descriptor = DmaBufImageDescriptor(
            fd: importFd,
            width: width,
            height: height,
            drmFormat: drmFormat,
            modifier: modifier,
            planes: importPlanes,
            usage: DmaBufImageDescriptor.sampledUsage)
        return importDmaBufImage(
            device: deviceHandle,
            dispatch: deviceDispatch,
            descriptor: descriptor) != nil
    }

    /// Copy and coalesce a client SHM update. GPU allocation/upload is deliberately
    /// deferred to `renderReady`, outside Wayland dispatch.
    @discardableResult
    public func registerSurfaceShm(
        iosurfaceID: UInt64, pixels: [UInt8],
        width: UInt32, height: UInt32, drmFormat: UInt32, stride: UInt32
    ) -> Bool {
        let commitInstant = telemetryClock.now
        guard iosurfaceID != 0, frameDriver != nil else { return false }
        guard let rgba = convertClientShmToRGBA(
            pixels: pixels, width: width, height: height, drmFormat: drmFormat, stride: stride)
        else { return false }
        let pending = PendingShmUpload(
            pixels: rgba, width: Int32(width), height: Int32(height), generation: nextGeneration())
        if pendingShmUploads.enqueue(pending, for: iosurfaceID) {
            clientUploadStats.coalesced &+= 1
        }
        clientUploadStats.enqueued &+= 1
        clientUploadStats.pendingBytes = pendingShmUploads.byteCount
        clientCommitInstants[iosurfaceID] = commitInstant
        return true
    }

    private func drainPendingShmUploads() {
        guard !pendingShmUploads.isEmpty, let driver = frameDriver else { return }
        let uploads = pendingShmUploads.drain()
        clientUploadStats.pendingBytes = 0
        for (iosurfaceID, pending) in uploads {
            guard let texture = driver.stageClientUpload(
                replacing: clientUploadTextures[iosurfaceID], pixels: pending.pixels,
                width: pending.width, height: pending.height)
            else {
                clientUploadStats.failed &+= 1
                continue
            }
            let image = texture.image()
            guard image.isValid() else {
                clientUploadStats.failed &+= 1
                continue
            }
            // Switching from DMA-BUF to SHM retires the borrowed image after the
            // presentation backend reports that asynchronous GPU use is complete.
            if let old = importedSurfaceImages[iosurfaceID] {
                retiredSurfaceImages.append((lastSubmittedSerial, old, iosurfaceID))
            }
            importedSurfaceImages[iosurfaceID] = nil
            if let old = clientUploadTextures.updateValue(texture, forKey: iosurfaceID) {
                retiredClientUploadTextures.append((lastSubmittedSerial, old))
            }
            driver.registry.register(
                handle: iosurfaceID, image: image,
                width: pending.width, height: pending.height,
                contentRevision: pending.generation)
            clientUploadStats.uploaded &+= 1
        }
    }

    // MARK: - Snapshots

    /// Register a captured/imported registry texture as a refcounted snapshot,
    /// returning the snapshot handle a layer's `.snapshot` content references.
    @discardableResult
    public func registerSnapshot(textureHandle: UInt64, width: Float, height: Float) -> UInt64 {
        snapshots.registerTextureHandle(
            NucleusRenderModel.TextureHandle(raw: textureHandle),
            size: Bounds(w: width, h: height)).raw
    }

    /// Drop one ref on a snapshot; on the final ref, evict its backing registry
    /// texture too.
    public func releaseSnapshot(_ snapshotHandle: UInt64) {
        if let texture = snapshots.release(SnapshotHandle(raw: snapshotHandle)) {
            _ = frameDriver?.registry.release(texture.raw)
        }
    }

    /// Drop a client surface's imported texture (surface destroyed / content
    /// detached). Evicts the registry entry + releases the backing VkImage.
    public func releaseSurfaceTexture(iosurfaceID: UInt64) {
        clientCommitInstants[iosurfaceID] = nil
        pendingClientAcquireSemaphores[iosurfaceID] = nil
        _ = frameDriver?.registry.release(iosurfaceID)
        _ = pendingShmUploads.remove(iosurfaceID)
        clientUploadStats.pendingBytes = pendingShmUploads.byteCount
        if let old = clientUploadTextures.removeValue(forKey: iosurfaceID) {
            retiredClientUploadTextures.append((lastSubmittedSerial, old))
        }
        if let old = importedSurfaceImages[iosurfaceID] {
            retiredSurfaceImages.append((lastSubmittedSerial, old, iosurfaceID))
        }
        importedSurfaceImages[iosurfaceID] = nil
    }

    /// Drop an acquire semaphore that the DRM direct-scanout path consumed through
    /// its duplicate sync_file. It was never submitted to Vulkan and is safe to
    /// destroy immediately after the atomic commit accepts the buffer.
    public func discardPendingSurfaceAcquire(iosurfaceID: UInt64) {
        pendingClientAcquireSemaphores[iosurfaceID] = nil
    }

    // MARK: - Teardown

    /// Drop the render resources (snapshots, frame driver accumulators + registry
    /// images, imported client-surface images) — step one of GPU-lifetime teardown,
    /// run BEFORE the backend tears down its own scanout/swapchain images.
    public func shutdownRenderResources() {
        snapshots.releaseAll { _ in }
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
        let graphiteCompletedSerial = frameDriver?.pollCompletedSubmissionSerial() ?? .max
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
