// `OutputBufferOwner` holds the three coupled scanout lifetimes (GBM BO ↔ Vulkan
// image ↔ KMS framebuffer) and destroys them exactly once, in reverse dependency order
// (the KMS fb references the BO's planes; the Vulkan image imports them). This
// transitional borrowed-`fb_id` seam. It also owns the mailbox render-target ring
// the renderer rotates through.
//
// The three lifetimes are passed as destroy closures so the owner composes over
// The renderer constructs it with the real teardown verbs.

/// One scanout buffer's coupled GBM/Vulkan/KMS lifetimes.
public struct OutputBufferOwner: ~Copyable {
    public let width: UInt32
    public let height: UInt32
    private let destroyFramebuffer: () -> Void
    private let destroyImage: () -> Void
    private let destroyBuffer: () -> Void

    public init(
        width: UInt32,
        height: UInt32,
        destroyFramebuffer: @escaping () -> Void,
        destroyImage: @escaping () -> Void,
        destroyBuffer: @escaping () -> Void
    ) {
        self.width = width
        self.height = height
        self.destroyFramebuffer = destroyFramebuffer
        self.destroyImage = destroyImage
        self.destroyBuffer = destroyBuffer
    }

    deinit {
        // Reverse dependency order: the KMS framebuffer references the BO planes
        // and the Vulkan image imports them, so tear down fb → image → BO.
        destroyFramebuffer()
        destroyImage()
        destroyBuffer()
    }
}

/// A fixed-capacity ring of render targets the renderer rotates through for
/// mailbox presentation. Generic over the per-slot target so it composes over
/// the Vulkan image / output-buffer owner without coupling here.
public struct MailboxRing {
    public let capacity: Int
    private var nextSlot: Int = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Advance to the next render slot (round-robin). Returns the slot index the
    /// caller should render into this frame.
    public mutating func acquireSlot() -> Int {
        let slot = nextSlot
        nextSlot = (nextSlot + 1) % capacity
        return slot
    }
}

/// A scanout-copy is the recorded blit of the composited target into the
/// presentation buffer when direct scanout is not eligible. Modeled here as the
/// source/target generation pair the renderer's frame queue resolves; the
/// recorded Vulkan copy binds in the renderer at the cutover.
public struct ScanoutCopy: Equatable, Sendable {
    public var sourceGeneration: UInt64
    public var targetGeneration: UInt64
    public init(sourceGeneration: UInt64, targetGeneration: UInt64) {
        self.sourceGeneration = sourceGeneration
        self.targetGeneration = targetGeneration
    }
}
