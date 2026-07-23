// `ScanoutSurface` assembles a `nucleus.skia.VulkanImageDescriptor` from a borrowed
// Vulkan scanout image and wraps it as a Graphite render-target `Surface` — the BO the compositor
// composites into and KMS flips. This is the render-target analog of
// `TextureRegistry.wrapBackendImage` (which produces a sampleable `Image`).
//
// The marshaling (`descriptor`) is hardware-independent and the verifiable unit.
// The wrap (`wrap`) couples to a live recorder. The bridge is image-source-
// agnostic: at the cutover the VkImage is the GBM-scanout-BO image from the
// attachment VkImage works.

public import VulkanC
public import Vulkan
import NucleusSkiaGraphiteBridge

/// A borrowed Vulkan scanout image plus the metadata the façade needs to wrap it
/// as a Graphite render target. Every handle is borrowed — see the lifetime
/// contract on `ScanoutSurface`.
public struct ScanoutImageParams {
    /// The borrowed `VkImage`. Must include `VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT`
    /// in `usageFlags` for the wrap to produce a render target.
    public var image: VkImage?
    /// The borrowed backing `VkDeviceMemory`, or nil (the façade tolerates a null
    /// memory for render targets).
    public var memory: VkDeviceMemory?
    /// Bound allocation size; 0 → indeterminate / borrowed.
    public var allocSize: UInt64
    public var width: Int32
    public var height: Int32
    public var format: VkFormat
    public var tiling: VkImageTiling
    /// The image's current layout (e.g. `VK_IMAGE_LAYOUT_UNDEFINED` for a fresh BO).
    public var initialLayout: VkImageLayout
    public var usageFlags: VK.ImageUsageFlags
    public var queueFamilyIndex: UInt32
    /// Premultiplied alpha vs opaque (false for an XRGB-style scanout BO).
    public var hasAlpha: Bool
    public var sampleCount: UInt32

    public init(
        image: VkImage?,
        memory: VkDeviceMemory?,
        allocSize: UInt64,
        width: Int32,
        height: Int32,
        format: VkFormat,
        tiling: VkImageTiling,
        initialLayout: VkImageLayout,
        usageFlags: VK.ImageUsageFlags,
        queueFamilyIndex: UInt32,
        hasAlpha: Bool,
        sampleCount: UInt32 = 1
    ) {
        self.image = image
        self.memory = memory
        self.allocSize = allocSize
        self.width = width
        self.height = height
        self.format = format
        self.tiling = tiling
        self.initialLayout = initialLayout
        self.usageFlags = usageFlags
        self.queueFamilyIndex = queueFamilyIndex
        self.hasAlpha = hasAlpha
        self.sampleCount = sampleCount
    }
}

/// Bridges a borrowed Vulkan scanout image to a Graphite render-target `Surface`.
///
/// LIFETIME CONTRACT: the borrowed `VkImage` (and its `VkDeviceMemory`) MUST
/// outlive the returned `Surface` — the façade never owns them. The `VkOwned`
/// holding the image must be destroyed only AFTER the Surface's scope ends, and
/// the whole chain torn down before the Graphite context. A Surface backed by a
/// backend texture faults if used after its backing is freed.
public enum ScanoutSurface {
    /// Pure marshaling: assemble the façade descriptor from the borrowed image.
    /// No GPU access — the hardware-independent unit. `VkImage`/`VkDeviceMemory`
    /// handles marshal to the descriptor's `void *` fields the same way device
    /// handles do (`UnsafeMutableRawPointer(handle)`); the `VkFormat` /
    /// `VkImageTiling` / `VkImageLayout` C enums lower to their `rawValue`.
    public static func descriptor(_ params: ScanoutImageParams) -> nucleus.skia.VulkanImageDescriptor {
        var desc = nucleus.skia.VulkanImageDescriptor()
        if let image = params.image { desc.image = UnsafeMutableRawPointer(image) }
        if let memory = params.memory { desc.memory = UnsafeMutableRawPointer(memory) }
        desc.allocSize = params.allocSize
        desc.format = params.format.rawValue
        desc.width = params.width
        desc.height = params.height
        desc.imageTiling = params.tiling.rawValue
        desc.imageLayout = params.initialLayout.rawValue
        desc.imageUsageFlags = params.usageFlags.rawValue
        desc.sampleCount = params.sampleCount
        desc.queueFamilyIndex = params.queueFamilyIndex
        desc.hasAlpha = params.hasAlpha
        return desc
    }

    /// Wrap the borrowed image as a Graphite render-target `Surface`. The returned
    /// Surface is invalid (`isValid() == false`) on an unusable descriptor (e.g. a
    /// null image, or `usageFlags` lacking `VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT`).
    public static func wrap(
        recorder: nucleus.skia.Recorder, params: ScanoutImageParams
    ) -> nucleus.skia.Surface {
        recorder.wrapBackendSurface(descriptor(params))
    }
}
