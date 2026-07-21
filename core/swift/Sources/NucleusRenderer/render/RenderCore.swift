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
import Tracy
import NucleusRenderModel
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

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
    public let resourceHost: SwiftResourceHost

    // Vulkan ownership (boxed noncopyable owners kept alive; their Copyable
    // handles/dispatch are copied out for per-frame use).
    var instanceLifetime: VulkanInstanceLifetime?
    var deviceBox: DeviceOwner?
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

    var context: nucleus.skia.GraphiteContext
    var frameDriver: FrameDriver?

    // Per-output presentation geometry (the agnostic `RenderTarget` the FramePlan
    // walk is parameterized by), keyed by output id. The backend registers each
    // output's geometry via `attachOutputGeometry`; `recordFrame` looks it up.
    var outputTargets: [UInt64: RenderTarget] = [:]
    var outputsNeedingInitialFrame: Set<UInt64> = []
    var outputPresentationLedger = OutputPresentationLedger()
    var frameSerial: UInt64 = 0
    public internal(set) var lastSubmittedSerial: UInt64 = 0
    @_spi(NucleusPlatform) public internal(set) var lastFrameTelemetry = RenderFrameTelemetry()
    @_spi(NucleusPlatform) public internal(set) var lastFrameAcquiredSurfaceIDs: [UInt64] = []
    var pendingFrameTelemetry: [RenderFrameTelemetry] = []
    let telemetryClock = ContinuousClock()
    var lastFrameRenderStarted: ContinuousClock.Instant?
    var clientCommitInstants: [UInt64: ContinuousClock.Instant] = [:]
    var lastFrameReferencedCommitInstants: [UInt64: ContinuousClock.Instant] = [:]
    var presentedCommitsAwaitingRevisionAck: [UInt64: ContinuousClock.Instant] = [:]

    // Imported client-surface dmabuf images, keyed by IOSurface id. The texture
    // registry wraps these as sampleable Graphite images but does NOT own the
    // backing `VkImage` — the box keeps it alive while the registry entry lives,
    // released on content swap / surface destroy / shutdown (before the Graphite
    // context, per the GPU-lifetime invariant).
    var importedSurfaceImages: [UInt64: VkOwnedImageBox] = [:]
    var retiredSurfaceImages: [(serial: UInt64, image: VkOwnedImageBox, releaseID: UInt64)] = []
    var pendingClientAcquireSemaphores: [UInt64: ClientAcquireSemaphore] = [:]
    var retiredClientAcquireSemaphores: [(serial: UInt64, semaphore: ClientAcquireSemaphore)] = []
    var pendingShmUploads = PendingShmUploadQueue()
    var clientUploadTextures: [UInt64: nucleus.skia.UploadTexture] = [:]
    var retiredClientUploadTextures: [(serial: UInt64, texture: nucleus.skia.UploadTexture)] = []
    var nextSnapshotContentRevision: UInt64 = 1
    public struct SnapshotTelemetry: Sendable, Equatable {
        public var captureAttempts: UInt64 = 0
        public var capturesSucceeded: UInt64 = 0
        public var capturesFailed: UInt64 = 0
        public var retirements: UInt64 = 0

        public init() {}
    }
    public internal(set) var snapshotTelemetry = SnapshotTelemetry()
    public internal(set) var outputAcquisitionCount: UInt64 = 0
    public struct ClientUploadStats: Sendable, Equatable {
        public var enqueued: UInt64 = 0
        public var coalesced: UInt64 = 0
        public var uploaded: UInt64 = 0
        public var failed: UInt64 = 0
        public var pendingBytes: UInt64 = 0
        public var fullSizeOwnedAllocations: UInt64 = 0
        public var ownedAllocationBytes: UInt64 = 0
        public var bytesCopied: UInt64 = 0
    }
    public internal(set) var clientUploadStats = ClientUploadStats()
    var startupFrameDiagnosticsRemaining = 12
    let sampleableDmaBufFormats: [DmaBufFormatModifier]
    var nextSurfaceId: UInt32 = 1
    var nextContentGeneration: UInt64 = 1
    var nextCaptureRequestID: UInt64 = 1

    @_spi(NucleusPlatform)
    public struct PixelCapture: Sendable, Equatable {
        public var pixels: [UInt8]
        public let width: Int
        public let height: Int
        public let originX: Int
        public let originY: Int

        public init(
            pixels: [UInt8], width: Int, height: Int,
            originX: Int = 0, originY: Int = 0
        ) {
            self.pixels = pixels
            self.width = width
            self.height = height
            self.originX = originX
            self.originY = originY
        }
    }

    struct PixelCaptureKey: Hashable {
        let outputID: UInt64
        let submissionSerial: UInt64
        let x: Int32
        let y: Int32
        let width: Int32
        let height: Int32
    }

    struct PixelCaptureSubscriber {
        let requestID: UInt64
        var completion: (@MainActor (PixelCapture?) -> Void)?
    }

    final class PendingPixelCaptureJob {
        let key: PixelCaptureKey?
        let readback: nucleus.skia.SurfaceReadback
        var retainedSurface: nucleus.skia.Surface?
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int
        let byteCount: Int
        let startedAt: ContinuousClock.Instant
        var subscribers: [PixelCaptureSubscriber]

        init(
            key: PixelCaptureKey?,
            readback: nucleus.skia.SurfaceReadback,
            retainedSurface: nucleus.skia.Surface?,
            originX: Int,
            originY: Int,
            width: Int,
            height: Int,
            byteCount: Int,
            startedAt: ContinuousClock.Instant,
            subscriber: PixelCaptureSubscriber
        ) {
            self.key = key
            self.readback = readback
            self.retainedSurface = retainedSurface
            self.originX = originX
            self.originY = originY
            self.width = width
            self.height = height
            self.byteCount = byteCount
            self.startedAt = startedAt
            subscribers = [subscriber]
        }
    }

    final class PendingDmabufCapture {
        let submissionSerial: UInt64
        var surface: nucleus.skia.Surface?
        let image: VkOwnedImageBox
        let startedAt: ContinuousClock.Instant
        var completion: (@MainActor (Bool) -> Void)?

        init(
            submissionSerial: UInt64,
            surface: nucleus.skia.Surface,
            image: VkOwnedImageBox,
            startedAt: ContinuousClock.Instant,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            self.submissionSerial = submissionSerial
            self.surface = surface
            self.image = image
            self.startedAt = startedAt
            self.completion = completion
        }

        func releaseBacking() {
            surface = nil
            image.release()
        }

        deinit {
            releaseBacking()
        }
    }

    static let maximumPendingPixelCaptureJobs = 8
    static let maximumPendingDmabufCaptureJobs = 16
    static let maximumPendingPixelCaptureBytes = 256 * 1024 * 1024
    static let capturePollMinimumNanoseconds: UInt64 = 250_000
    static let capturePollMaximumNanoseconds: UInt64 = 16_000_000
    static let captureStallNanoseconds: UInt64 = 10_000_000_000

    var pendingPixelCaptureJobs: [UInt64: PendingPixelCaptureJob] = [:]
    var pixelCaptureJobByKey: [PixelCaptureKey: UInt64] = [:]
    var pixelCaptureJobByRequest: [UInt64: UInt64] = [:]
    var pendingPixelCaptureBytes = 0
    var pendingDmabufCaptures: [UInt64: PendingDmabufCapture] = [:]
    var capturePollDelayNanoseconds =
        RenderCore.capturePollMinimumNanoseconds
    var coalescedPixelCaptureCount: UInt64 = 0
    var rejectedCaptureCount: UInt64 = 0
    @_spi(NucleusPlatform)
    public internal(set) var captureWorkStalled = false

    // Snapshot registry: refcounted snapshot handles over the texture registry.
    let snapshots: SnapshotService

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
    public internal(set) var lockComposition: [UInt64: Set<ContextID>]?
    /// The retained layer contexts each presentation target is allowed to walk.
    ///
    /// A compositor output defaults to the compositor context. Standalone
    /// clients explicitly associate their own scene context with each
    /// swapchain surface, which prevents unrelated surface roots from leaking
    /// into one another merely because they share a render store.
    var outputRootContexts: [UInt64: [ContextID]] = [:]

    /// Set when `lockComposition` last changed and a forced redraw has not yet
    /// presented. A lock beginning need not damage the retained tree (non-lock windows
    /// stay hosted; the blank is a composition-time filter), so the damage gate alone
    /// would leave stale unlocked content on screen. This forces the transition frame.
    var lockCompositionGeneration: UInt64 = 0

    init(
        instanceLifetime: VulkanInstanceLifetime, device: consuming DeviceOwner, queue: VkQueue,
        physicalDevice: VkPhysicalDevice, graphicsFamily: UInt32,
        context: nucleus.skia.GraphiteContext, driver: FrameDriver,
        store: RetainedTreeStore, resourceHost: SwiftResourceHost
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
        self.store = store
        self.resourceHost = resourceHost
        self.snapshots = resourceHost.snapshots
        self.sampleableDmaBufFormats = querySampleableDmaBufFormats(
            physicalDevice: physicalDevice, instanceDispatch: ownedInstanceDispatch)
        self.instanceLifetime = instanceLifetime
        self.deviceBox = consume device
    }

}
