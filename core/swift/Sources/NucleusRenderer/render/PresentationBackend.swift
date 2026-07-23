// The presentation-backend boundary: the render core is platform-agnostic and
// trades in these types; the concrete backend (Linux DRM/KMS scanout, Android
// Vulkan swapchain) implements the protocol. No DRM or swapchain type appears in
// any signature here — the platform difference lives entirely in which backend is
// constructed and what it hands back from `acquireTarget` / does in `present`.
//
// The render core (`RendererRuntime`'s agnostic half) drives the loop: for each
// presentable output it asks the backend to acquire the GPU image to record into,
// records the retained tree into it (Vulkan Graphite), and asks the backend to
// scan out / queue-present it. The backend owns output discovery, the per-output
// ring/slot or swapchain, page-flip / present pacing, and session lifecycle.

public import VulkanC
public import Vulkan

/// What kind of GPU image the core is recording into — selects the Vulkan image
/// usage flags the Graphite render-target wrap needs. The image itself is owned by
/// the backend (a GBM scanout BO on Linux, a swapchain image on Android); the core
/// only borrows it for the duration of one recorded frame.
public enum FrameTargetKind {
    /// A DRM/KMS scanout buffer object imported as a Vulkan image (Linux).
    case drmScanout
    /// A Vulkan swapchain image (Android `VK_KHR_android_surface`).
    case swapchainColor
}

/// The GPU image the core records one frame into, described in agnostic terms.
/// Every field is a raw C Vulkan type (from `VulkanC`, shared across
/// modules) or a primitive, so any backend — in any module — can construct it
/// without depending on the core's generated `VK.*` wrapper types. The backend
/// keeps ownership of the underlying image; this is a borrow for one frame.
public struct AcquiredFrameTarget {
    /// The borrowed color-attachment `VkImage` the frame is composited into.
    public var image: VkImage?
    public var width: Int32
    public var height: Int32
    public var format: VkFormat
    public var tiling: VkImageTiling
    /// The image's current layout when acquired (`VK_IMAGE_LAYOUT_UNDEFINED` for a
    /// fresh scanout BO or a just-acquired swapchain image).
    public var initialLayout: VkImageLayout
    /// The exact usage flags the backend used when the image was created. The
    /// render core forwards these unchanged to Graphite; it must not reconstruct
    /// them from the target kind because Vulkan validates the real image contract.
    public var usageFlags: VK.ImageUsageFlags
    public var queueFamily: UInt32
    /// Premultiplied alpha vs opaque (false for an XRGB-style scanout BO).
    public var hasAlpha: Bool
    public var kind: FrameTargetKind
    /// WSI swapchain only (`kind == .swapchainColor`): the acquire semaphore the
    /// GPU work waits on before rendering, and the semaphore signaled when it
    /// completes (the one `vkQueuePresentKHR` waits on). DRM scanout requires
    /// `signalSemaphore` as the exportable render-complete semaphore KMS consumes;
    /// only `waitSemaphore` is nil on that path.
    public var waitSemaphore: VkSemaphore?
    public var signalSemaphore: VkSemaphore?

    public init(
        image: VkImage?,
        width: Int32,
        height: Int32,
        format: VkFormat,
        tiling: VkImageTiling,
        initialLayout: VkImageLayout,
        usageFlags: VK.ImageUsageFlags,
        queueFamily: UInt32,
        hasAlpha: Bool,
        kind: FrameTargetKind,
        waitSemaphore: VkSemaphore? = nil,
        signalSemaphore: VkSemaphore? = nil
    ) {
        self.image = image
        self.width = width
        self.height = height
        self.format = format
        self.tiling = tiling
        self.initialLayout = initialLayout
        self.usageFlags = usageFlags
        self.queueFamily = queueFamily
        self.hasAlpha = hasAlpha
        self.kind = kind
        self.waitSemaphore = waitSemaphore
        self.signalSemaphore = signalSemaphore
    }
}

/// The platform presentation backend the agnostic render core drives. Outputs are
/// identified by a stable `UInt64` id (the connector id on Linux, a single id on
/// Android); the backend maps the id to its own per-output state (DRM output +
/// scanout ring, or the swapchain). `@MainActor` because the render path runs on
/// the compositor's single main-loop thread, alongside the retained store.
@MainActor
public protocol PresentationBackend: AnyObject {
    /// True when the backend's submit is asynchronous and it will explicitly tell
    /// RenderCore when GPU-referenced retired resources are safe to reclaim.
    var defersGpuResourceRetirement: Bool { get }
    /// The outputs that currently have a render destination, in render order.
    func presentableOutputIDs() -> [UInt64]

    /// Whether `outputID` can accept a new frame this turn (e.g. no KMS page flip
    /// is still in flight). The core skips outputs that are not ready.
    func isReadyToPresent(_ outputID: UInt64) -> Bool

    /// Attempt to present `outputID` by scanning out a client buffer directly on the
    /// primary plane, bypassing composition entirely (no `acquireTarget`/record). Returns
    /// true when the output was presented this way; the core then skips it. Returns false
    /// when the output is not eligible or the direct flip failed, and the core falls back
    /// to compositing it normally. Default: false (never direct-scanout — the WSI/Android
    /// backend always composites).
    func tryDirectScanout(_ outputID: UInt64) -> Bool

    /// Acquire the GPU image the core records this frame into for `outputID`
    /// (advancing the scanout ring or acquiring the next swapchain image). Returns
    /// nil when no image is available this turn (the core skips the output). The
    /// backend remembers which slot/image it handed out so `present` scans out the
    /// same one.
    func acquireTarget(_ outputID: UInt64) -> AcquiredFrameTarget?

    /// Close the backend's frame slot after the renderer successfully submitted
    /// work for the acquired target. WSI uses this to enqueue a fence-bearing
    /// completion marker after Graphite's opaque queue submission.
    func didSubmitTarget(_ outputID: UInt64) -> Bool

    /// Scan out / queue-present the image last acquired for `outputID` (the frame
    /// the core just recorded). Returns true on a successful flip/present.
    func present(_ outputID: UInt64) -> Bool

    /// Undo a successful `acquireTarget` whose frame the core could not submit.
    /// WSI consumes the acquire semaphore and releases the checked-out image with
    /// `VK_KHR_swapchain_maintenance1`; the DRM ring has no acquire side effect.
    func discardAcquiredTarget(_ outputID: UInt64)

    /// Whether the backend needs `outputID` to present this pass even though the
    /// retained tree has no pending damage — e.g. the hardware cursor plane moved and
    /// its new position must reach a commit. The core folds this into its per-output
    /// damage gate alongside the forced-present cases (session lock). Default: false.
    func wantsPresent(_ outputID: UInt64) -> Bool

    /// Called after a render pass in which at least one output presented, so the
    /// backend can release any per-frame resources it deferred (e.g. signal a
    /// client buffer's release syncobj).
    func didPresentFrame()

    /// Suspend presentation (VT-switch-away on Linux; surface loss on Android).
    func pauseSession()

    /// Resume presentation (VT-switch-back on Linux; surface re-create on Android).
    func resumeSession()
}

public extension PresentationBackend {
    var defersGpuResourceRetirement: Bool { false }
    func didSubmitTarget(_ outputID: UInt64) -> Bool { true }
    /// Default: nothing to undo. Correct for the DRM ring, whose `acquireTarget`
    /// only picks a slot (no semaphore and no checked-out WSI image).
    func discardAcquiredTarget(_ outputID: UInt64) {}

    /// Default: no extra present demand. The DRM backend overrides this to force a
    /// present when the hardware cursor moved with no tree damage.
    func wantsPresent(_ outputID: UInt64) -> Bool { false }

    /// Default: never direct-scanout. The DRM backend overrides this; the WSI/Android
    /// backend always composites.
    func tryDirectScanout(_ outputID: UInt64) -> Bool { false }
}
