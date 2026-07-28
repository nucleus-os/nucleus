// device as a VkImage. Used for both committed Wayland client buffers and the
// GBM scanout BO. The pNext chain assembly (external-memory + explicit DRM
// modifier plane layouts) and live import bind imported memory to the image.

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import NucleusDiagnostics
public import VulkanC
public import Vulkan

private func logDmaBufImportFailure(_ descriptor: DmaBufImageDescriptor, _ stage: String) {
    NucleusLogger(subsystem: "dmabuf-import").error(
        "failed stage=\(stage) size=\(descriptor.width)x\(descriptor.height) "
            + "format=\(descriptor.drmFormat) modifier=\(descriptor.modifier) "
            + "planes=\(descriptor.planes.count)")
}

public struct DmaBufPlane: Equatable, Sendable {
    /// Borrowed or owned dmabuf fd for this plane. `-1` means use the
    /// descriptor's primary fd. `importDmaBufImage` consumes the fds it receives.
    public var fd: Int32
    public var offset: UInt64
    public var rowPitch: UInt64
    public init(fd: Int32 = -1, offset: UInt64, rowPitch: UInt64) {
        self.fd = fd
        self.offset = offset
        self.rowPitch = rowPitch
    }
}

public struct DmaBufImageDescriptor {
    public var fd: Int32
    public var width: UInt32
    public var height: UInt32
    /// DRM fourcc (e.g. `DRM_FORMAT_XRGB8888`).
    public var drmFormat: UInt32
    public var modifier: UInt64
    public var planes: [DmaBufPlane]
    /// The image usage the import is created with. The default
    /// (`sampled | colorAttachment`) suits a sampled client buffer; a GBM scanout
    /// BO that Graphite wraps as a render target must add `inputAttachment` (Skia
    /// `transferSrc` for readback.
    public var usage: VK.ImageUsageFlags

    public static let sampledUsage: VK.ImageUsageFlags = [.sampledBit, .colorAttachmentBit]
    public static let scanoutUsage: VK.ImageUsageFlags = [.colorAttachmentBit, .inputAttachmentBit, .transferSrcBit]

    public init(
        fd: Int32, width: UInt32, height: UInt32, drmFormat: UInt32, modifier: UInt64,
        planes: [DmaBufPlane], usage: VK.ImageUsageFlags = DmaBufImageDescriptor.sampledUsage
    ) {
        self.fd = fd
        self.width = width
        self.height = height
        self.drmFormat = drmFormat
        self.modifier = modifier
        self.planes = planes
        self.usage = usage
    }
}

public enum DrmFourcc {
    public static let xrgb8888: UInt32 = 0x3432_5258  // 'XR24'
    public static let argb8888: UInt32 = 0x3432_5241  // 'AR24'
    public static let xbgr8888: UInt32 = 0x3432_4258  // 'XB24'
    public static let abgr8888: UInt32 = 0x3432_4241  // 'AB24'
    public static let abgr16161616f: UInt32 = 0x4834_4241  // 'AB4H'
    public static let abgr2101010: UInt32 = 0x3033_4241  // 'AB30'
}

struct ClientShmConversionMetrics: Equatable, Sendable {
    var fullSizeOwnedAllocations: UInt64
    var ownedAllocationBytes: UInt64
    var bytesCopied: UInt64
}

struct ClientShmConversion: Equatable, Sendable {
    var pixels: [UInt8]
    var metrics: ClientShmConversionMetrics
}

/// Convert a committed wl_shm client buffer into the RGBA byte layout consumed
/// by `makeRasterImageRGBA`. wl_shm's ARGB8888/XRGB8888 values map to DRM
/// AR24/XR24, whose little-endian memory order is BGRA/BGRX.
public func convertClientShmToRGBA(
    pixels: Span<UInt8>,
    width: UInt32,
    height: UInt32,
    drmFormat: UInt32,
    stride: UInt32
) -> [UInt8]? {
    convertClientShmToRGBAWithMetrics(
        pixels: pixels,
        width: width,
        height: height,
        drmFormat: drmFormat,
        stride: stride
    )?.pixels
}

func convertClientShmToRGBAWithMetrics(
    pixels: Span<UInt8>,
    width: UInt32,
    height: UInt32,
    drmFormat: UInt32,
    stride: UInt32
) -> ClientShmConversion? {
    guard width > 0, height > 0 else { return nil }

    let (minimumStride, minimumStrideOverflow) =
        UInt64(width).multipliedReportingOverflow(by: 4)
    guard !minimumStrideOverflow, UInt64(stride) >= minimumStride else { return nil }

    let (sourceByteCount, sourceByteCountOverflow) =
        UInt64(stride).multipliedReportingOverflow(by: UInt64(height))
    let (pixelCount, pixelCountOverflow) =
        UInt64(width).multipliedReportingOverflow(by: UInt64(height))
    let (destinationByteCount, destinationByteCountOverflow) =
        pixelCount.multipliedReportingOverflow(by: 4)
    guard
        !sourceByteCountOverflow,
        !pixelCountOverflow,
        !destinationByteCountOverflow,
        let sourceCount = Int(exactly: sourceByteCount),
        let destinationCount = Int(exactly: destinationByteCount),
        let rowStride = Int(exactly: stride),
        let destinationRowBytes = Int(exactly: minimumStride),
        pixels.count >= sourceCount
    else { return nil }

    let opaque: Bool
    switch drmFormat {
    case DrmFourcc.argb8888:
        opaque = false
    case DrmFourcc.xrgb8888:
        opaque = true
    default:
        return nil
    }

    let converted = unsafe [UInt8](unsafeUninitializedCapacity: destinationCount) {
        destination, initializedCount in
        guard let destinationBase = destination.baseAddress else {
            initializedCount = 0
            return
        }
        for y in 0..<Int(height) {
            let sourceRow = y * rowStride
            let destinationRow = unsafe destinationBase.advanced(by: y * destinationRowBytes)
            for x in 0..<Int(width) {
                let sourcePixel = sourceRow + x * 4
                let destinationPixel = unsafe destinationRow.advanced(by: x * 4)
                unsafe destinationPixel[0] = pixels[sourcePixel + 2]
                unsafe destinationPixel[1] = pixels[sourcePixel + 1]
                unsafe destinationPixel[2] = pixels[sourcePixel]
                unsafe destinationPixel[3] = opaque ? 255 : pixels[sourcePixel + 3]
            }
        }
        initializedCount = destinationCount
    }
    return ClientShmConversion(
        pixels: converted,
        metrics: ClientShmConversionMetrics(
            fullSizeOwnedAllocations: 1,
            ownedAllocationBytes: UInt64(destinationCount),
            bytesCopied: UInt64(destinationCount)))
}

public struct DmaBufFormatModifier: Equatable, Sendable {
    public var format: UInt32
    public var modifier: UInt64

    public init(format: UInt32, modifier: UInt64) {
        self.format = format
        self.modifier = modifier
    }
}

public struct DmaBufSyncPoint: Equatable, Sendable {
    public var handle: UInt32
    public var point: UInt64

    public init(handle: UInt32, point: UInt64) {
        self.handle = handle
        self.point = point
    }
}

/// One client-owned Vulkan image exported as a DMA-BUF backing store. The
/// Vulkan image and memory remain process-local; only a duplicated DMA-BUF file
/// descriptor and value metadata are transferred to Wayland.
@safe public final class ExportedDmaBufImage {
    private let image: VkOwnedImageBox
    private let rawImage: VkImage
    private var fileDescriptor: Int32
    public let width: UInt32
    public let height: UInt32
    public let drmFormat: UInt32
    public let modifier: UInt64
    public let offset: UInt32
    public let rowPitch: UInt32

    init(
        image: consuming VkOwned<VkImage>,
        fileDescriptor: Int32,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        offset: UInt32,
        rowPitch: UInt32
    ) {
        unsafe self.rawImage = image.handle
        unsafe self.image = VkOwnedImageBox(consuming: image)
        self.fileDescriptor = fileDescriptor
        self.width = width
        self.height = height
        self.drmFormat = drmFormat
        self.modifier = modifier
        self.offset = offset
        self.rowPitch = rowPitch
    }

    public var imageHandle: VkImage? {
        unsafe rawImage
    }

    /// Transfer the exported DMA-BUF descriptor exactly once. The Vulkan image
    /// and its memory remain owned here after the descriptor is sent to Wayland.
    public func takeFileDescriptor() -> Int32? {
        guard fileDescriptor >= 0 else { return nil }
        let descriptor = fileDescriptor
        fileDescriptor = -1
        return descriptor
    }

    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }
}

/// One process-local Vulkan timeline semaphore exported to Wayland as a DRM
/// syncobj timeline. Graphite submits first on `queue`; `signal(_:)` then
/// appends an empty submit on that same queue, making the published acquire
/// point an exact completion marker without a CPU wait.
@MainActor
@safe public final class ExportedTimelineSemaphore {
    private let device: VkDevice
    private let dispatch: VK.DeviceDispatch
    private let queue: VkQueue
    public let semaphore: VkSemaphore
    private var fileDescriptor: Int32
    public private(set) var lastResult: VkResult = VK_SUCCESS

    public var deviceLost: Bool {
        lastResult == VK_ERROR_DEVICE_LOST
    }

    public init?(
        device: VkDevice,
        dispatch: VK.DeviceDispatch,
        queue: VkQueue
    ) {
        guard let createSemaphore = unsafe dispatch.vkCreateSemaphore,
              let getSemaphoreFd = unsafe dispatch.vkGetSemaphoreFdKHR
        else { return nil }

        var exportInfo = unsafe VkExportSemaphoreCreateInfo()
        unsafe exportInfo.sType =
            VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO
        unsafe exportInfo.handleTypes = VkExternalSemaphoreHandleTypeFlags(
            VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT.rawValue)

        var typeInfo = unsafe VkSemaphoreTypeCreateInfo()
        unsafe typeInfo.sType =
            VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
        unsafe typeInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE
        unsafe typeInfo.initialValue = 0

        var createInfo = unsafe VkSemaphoreCreateInfo()
        unsafe createInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var created: VkSemaphore?
        let result = withUnsafePointer(to: &exportInfo) { exportPointer in
            withUnsafeMutablePointer(to: &typeInfo) { typePointer in
                unsafe typePointer.pointee.pNext =
                    UnsafeRawPointer(exportPointer)
                unsafe createInfo.pNext = UnsafeRawPointer(typePointer)
                return unsafe createSemaphore(
                    device, &createInfo, nil, &created)
            }
        }
        guard result == VK_SUCCESS, let created = unsafe created else {
            return nil
        }

        var fdInfo = unsafe VkSemaphoreGetFdInfoKHR()
        unsafe fdInfo.sType =
            VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR
        unsafe fdInfo.semaphore = created
        unsafe fdInfo.handleType =
            VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT
        var descriptor: Int32 = -1
        guard unsafe getSemaphoreFd(
            device, &fdInfo, &descriptor) == VK_SUCCESS,
              descriptor >= 0
        else {
            unsafe dispatch.vkDestroySemaphore?(
                device, created, nil)
            return nil
        }

        unsafe self.device = device
        self.dispatch = dispatch
        unsafe self.queue = queue
        unsafe self.semaphore = created
        self.fileDescriptor = descriptor
    }

    public func takeFileDescriptor() -> Int32? {
        guard fileDescriptor >= 0 else { return nil }
        let descriptor = fileDescriptor
        fileDescriptor = -1
        return descriptor
    }

    public func currentValue() -> UInt64? {
        guard let getValue =
            unsafe dispatch.vkGetSemaphoreCounterValue
        else { return nil }
        var value: UInt64 = 0
        lastResult = unsafe getValue(
            device, semaphore, &value)
        guard lastResult == VK_SUCCESS else { return nil }
        return value
    }

    /// Append a timeline signal after all work already submitted to the shared
    /// graphics queue.
    public func signal(_ value: UInt64) -> Bool {
        guard value > 0,
              let queueSubmit2 = unsafe dispatch.vkQueueSubmit2
        else { return false }
        var signalInfo = unsafe VkSemaphoreSubmitInfo()
        unsafe signalInfo.sType =
            VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO
        unsafe signalInfo.semaphore = semaphore
        unsafe signalInfo.value = value
        unsafe signalInfo.stageMask =
            VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT

        var submitInfo = unsafe VkSubmitInfo2()
        unsafe submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2
        unsafe submitInfo.signalSemaphoreInfoCount = 1
        lastResult = withUnsafePointer(to: &signalInfo) { signalPointer in
            unsafe submitInfo.pSignalSemaphoreInfos = signalPointer
            return unsafe queueSubmit2(
                queue, 1, &submitInfo, nil)
        }
        return lastResult == VK_SUCCESS
    }

    isolated deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        unsafe dispatch.vkDestroySemaphore?(
            device, semaphore, nil)
    }
}

/// Map a DRM fourcc to the Vulkan format Skia/the compositor sample it as.
public func vulkanFormatForDrm(_ fourcc: UInt32) -> VkFormat {
    switch fourcc {
    case DrmFourcc.xrgb8888, DrmFourcc.argb8888:
        return VK_FORMAT_B8G8R8A8_UNORM
    case DrmFourcc.xbgr8888, DrmFourcc.abgr8888:
        return VK_FORMAT_R8G8B8A8_UNORM
    case DrmFourcc.abgr16161616f:
        return VK_FORMAT_R16G16B16A16_SFLOAT
    case DrmFourcc.abgr2101010:
        return VK_FORMAT_A2B10G10R10_UNORM_PACK32
    default:
        return VK_FORMAT_UNDEFINED
    }
}

/// Allocate a single-plane DRM-modifier Vulkan image whose memory can be
/// exported as a DMA-BUF. This is the client backing-store allocation path: the
/// returned owner retains the process-local image and memory while its exported
/// descriptor is transferred to `zwp_linux_dmabuf_v1`.
public func allocateExportedDmaBufImage(
    physicalDevice: VkPhysicalDevice,
    instanceDispatch: VK.InstanceDispatch,
    device: VkDevice,
    deviceDispatch: VK.DeviceDispatch,
    width: UInt32,
    height: UInt32,
    drmFormat: UInt32,
    modifier: UInt64
) -> ExportedDmaBufImage? {
    guard width > 0,
          height > 0,
          vulkanFormatForDrm(drmFormat) != VK_FORMAT_UNDEFINED,
          let getMemoryProperties =
            unsafe instanceDispatch.vkGetPhysicalDeviceMemoryProperties,
          let createImage = unsafe deviceDispatch.vkCreateImage,
          let destroyImage = unsafe deviceDispatch.vkDestroyImage,
          let getRequirements =
            unsafe deviceDispatch.vkGetImageMemoryRequirements,
          let allocateMemory = unsafe deviceDispatch.vkAllocateMemory,
          let freeMemory = unsafe deviceDispatch.vkFreeMemory,
          let bindImageMemory = unsafe deviceDispatch.vkBindImageMemory,
          let getMemoryFd = unsafe deviceDispatch.vkGetMemoryFdKHR,
          let getModifier =
            unsafe deviceDispatch.vkGetImageDrmFormatModifierPropertiesEXT,
          let getLayout = unsafe deviceDispatch.vkGetImageSubresourceLayout
    else {
        return nil
    }

    var selectedModifier = modifier
    var modifierList = unsafe VkImageDrmFormatModifierListCreateInfoEXT()
    unsafe modifierList.sType =
        VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT
    unsafe modifierList.drmFormatModifierCount = 1

    var externalImage = unsafe VkExternalMemoryImageCreateInfo()
    unsafe externalImage.sType =
        VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
    unsafe externalImage.handleTypes =
        VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT.rawValue

    var createInfo = unsafe VkImageCreateInfo()
    unsafe createInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    unsafe createInfo.imageType = VK_IMAGE_TYPE_2D
    unsafe createInfo.format = vulkanFormatForDrm(drmFormat)
    unsafe createInfo.extent = VkExtent3D(
        width: width, height: height, depth: 1)
    unsafe createInfo.mipLevels = 1
    unsafe createInfo.arrayLayers = 1
    unsafe createInfo.samples = VK_SAMPLE_COUNT_1_BIT
    unsafe createInfo.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
    unsafe createInfo.usage =
        DmaBufImageDescriptor.scanoutUsage.rawValue
    unsafe createInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    unsafe createInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED

    var image: VkImage?
    let createResult = withUnsafePointer(to: &selectedModifier) {
        selectedModifierPointer in
        unsafe modifierList.pDrmFormatModifiers =
            selectedModifierPointer
        return withUnsafePointer(to: &modifierList) {
            modifierListPointer in
            unsafe externalImage.pNext =
                UnsafeRawPointer(modifierListPointer)
            return withUnsafePointer(to: &externalImage) {
                externalImagePointer in
                unsafe createInfo.pNext =
                    UnsafeRawPointer(externalImagePointer)
                return unsafe createImage(
                    device, &createInfo, nil, &image)
            }
        }
    }
    guard createResult == VK_SUCCESS, let image = unsafe image else {
        return nil
    }
    var ownsImage = true
    var memory: VkDeviceMemory?
    defer {
        if let memory = unsafe memory {
            unsafe freeMemory(device, memory, nil)
        }
        if ownsImage {
            unsafe destroyImage(device, image, nil)
        }
    }

    var requirements = VkMemoryRequirements()
    unsafe getRequirements(device, image, &requirements)
    guard requirements.memoryTypeBits != 0 else { return nil }

    var memoryProperties = VkPhysicalDeviceMemoryProperties()
    unsafe getMemoryProperties(physicalDevice, &memoryProperties)
    let memoryTypeIndex =
        UInt32(requirements.memoryTypeBits.trailingZeroBitCount)
    guard memoryTypeIndex < memoryProperties.memoryTypeCount else {
        return nil
    }

    var dedicated = unsafe VkMemoryDedicatedAllocateInfo()
    unsafe dedicated.sType =
        VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
    unsafe dedicated.image = image

    var exportInfo = unsafe VkExportMemoryAllocateInfo()
    unsafe exportInfo.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO
    unsafe exportInfo.handleTypes =
        VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT.rawValue

    var allocateInfo = unsafe VkMemoryAllocateInfo()
    unsafe allocateInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    unsafe allocateInfo.allocationSize = requirements.size
    unsafe allocateInfo.memoryTypeIndex = memoryTypeIndex
    let allocateResult = withUnsafePointer(to: &dedicated) {
        dedicatedPointer in
        unsafe exportInfo.pNext = UnsafeRawPointer(dedicatedPointer)
        return withUnsafePointer(to: &exportInfo) {
            exportInfoPointer in
            unsafe allocateInfo.pNext =
                UnsafeRawPointer(exportInfoPointer)
            return unsafe allocateMemory(
                device, &allocateInfo, nil, &memory)
        }
    }
    guard allocateResult == VK_SUCCESS, let boundMemory = unsafe memory else {
        return nil
    }
    guard unsafe bindImageMemory(device, image, boundMemory, 0)
        == VK_SUCCESS
    else {
        return nil
    }

    var modifierProperties =
        unsafe VkImageDrmFormatModifierPropertiesEXT()
    unsafe modifierProperties.sType =
        VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT
    guard unsafe getModifier(
        device, image, &modifierProperties) == VK_SUCCESS
    else {
        return nil
    }

    var subresource = VkImageSubresource()
    subresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT.rawValue
    var layout = VkSubresourceLayout()
    unsafe getLayout(device, image, &subresource, &layout)
    guard let offset = UInt32(exactly: layout.offset),
          let rowPitch = UInt32(exactly: layout.rowPitch)
    else {
        return nil
    }

    var fdInfo = unsafe VkMemoryGetFdInfoKHR()
    unsafe fdInfo.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR
    unsafe fdInfo.memory = boundMemory
    unsafe fdInfo.handleType =
        VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT
    var exportedFD: Int32 = -1
    guard unsafe getMemoryFd(device, &fdInfo, &exportedFD) == VK_SUCCESS,
          exportedFD >= 0
    else {
        return nil
    }

    unsafe memory = nil
    ownsImage = false
    let owner = unsafe VkOwned(
        adopting: image,
        device: device,
        destroy: { device, image in
            unsafe destroyImage(device, image, nil)
            unsafe freeMemory(device, boundMemory, nil)
        })
    return unsafe ExportedDmaBufImage(
        image: owner,
        fileDescriptor: exportedFD,
        width: width,
        height: height,
        drmFormat: drmFormat,
        modifier: modifierProperties.drmFormatModifier,
        offset: offset,
        rowPitch: rowPitch)
}

/// Query the selected Vulkan physical device for DRM format modifiers that can be
/// sampled as imported client textures. This is the source for
/// zwp_linux_dmabuf feedback; clients should only allocate buffers the renderer's
/// actual Vulkan device says it can sample.
public func querySampleableDmaBufFormats(
    physicalDevice: VkPhysicalDevice,
    instanceDispatch: VK.InstanceDispatch,
    drmFormats: [UInt32] = [
        DrmFourcc.xrgb8888,
        DrmFourcc.argb8888,
        DrmFourcc.xbgr8888,
        DrmFourcc.abgr8888,
        DrmFourcc.abgr16161616f,
        DrmFourcc.abgr2101010,
    ]
) -> [DmaBufFormatModifier] {
    guard let getFormatProperties = unsafe instanceDispatch.vkGetPhysicalDeviceFormatProperties2,
          let getImageFormatProperties = unsafe instanceDispatch.vkGetPhysicalDeviceImageFormatProperties2
    else {
        return []
    }

    var out: [DmaBufFormatModifier] = []
    for drmFormat in drmFormats {
        let vulkanFormat = vulkanFormatForDrm(drmFormat)
        guard vulkanFormat != VK_FORMAT_UNDEFINED else { continue }
        var list = unsafe VkDrmFormatModifierPropertiesList2EXT()
        unsafe list.sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_2_EXT

        var props = unsafe VkFormatProperties2()
        unsafe props.sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2
        withUnsafeMutablePointer(to: &list) { listPtr in
            unsafe props.pNext = UnsafeMutableRawPointer(listPtr)
            unsafe getFormatProperties(physicalDevice, vulkanFormat, &props)
        }
        guard unsafe list.drmFormatModifierCount > 0 else { continue }

        var modifiers = unsafe [VkDrmFormatModifierProperties2EXT](
            repeating: VkDrmFormatModifierProperties2EXT(),
            count: Int(list.drmFormatModifierCount))
        modifiers.withUnsafeMutableBufferPointer { buffer in
            unsafe list.pDrmFormatModifierProperties = buffer.baseAddress
            withUnsafeMutablePointer(to: &list) { listPtr in
                unsafe props.pNext = UnsafeMutableRawPointer(listPtr)
                unsafe getFormatProperties(physicalDevice, vulkanFormat, &props)
            }
        }

        for modifier in modifiers {
            let features = modifier.drmFormatModifierTilingFeatures
            if features & UInt64(VK_FORMAT_FEATURE_2_SAMPLED_IMAGE_BIT) == 0 { continue }

            // Modifier tiling support alone does not mean an image allocated by a
            // Wayland client can be imported. NVIDIA in particular exposes sampled
            // modifiers which fail the external-memory import path. Advertising one
            // lets the client create a perfectly valid buffer that this compositor
            // can never turn into a texture, producing an invisible surface.
            var externalInfo = unsafe VkPhysicalDeviceExternalImageFormatInfo()
            unsafe externalInfo.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO
            unsafe externalInfo.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT

            var modifierInfo = unsafe VkPhysicalDeviceImageDrmFormatModifierInfoEXT()
            unsafe modifierInfo.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT
            unsafe modifierInfo.drmFormatModifier = modifier.drmFormatModifier
            unsafe modifierInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE

            var imageInfo = unsafe VkPhysicalDeviceImageFormatInfo2()
            unsafe imageInfo.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2
            unsafe imageInfo.format = vulkanFormat
            unsafe imageInfo.type = VK_IMAGE_TYPE_2D
            unsafe imageInfo.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
            unsafe imageInfo.usage = DmaBufImageDescriptor.sampledUsage.rawValue

            var externalProperties = unsafe VkExternalImageFormatProperties()
            unsafe externalProperties.sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES
            var imageProperties = unsafe VkImageFormatProperties2()
            unsafe imageProperties.sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2
            let supported = withUnsafePointer(to: &externalInfo) { externalPtr in
                unsafe modifierInfo.pNext = unsafe UnsafeRawPointer(externalPtr)
                return withUnsafePointer(to: &modifierInfo) { modifierPtr in
                    unsafe imageInfo.pNext = unsafe UnsafeRawPointer(modifierPtr)
                    return withUnsafeMutablePointer(to: &externalProperties) { externalPropertiesPtr in
                        unsafe imageProperties.pNext = UnsafeMutableRawPointer(externalPropertiesPtr)
                        return unsafe getImageFormatProperties(physicalDevice, &imageInfo, &imageProperties)
                    }
                }
            }
            guard supported == VK_SUCCESS else { continue }
            let externalFeatures = unsafe externalProperties.externalMemoryProperties.externalMemoryFeatures
            guard externalFeatures & VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT.rawValue != 0 else { continue }
            out.append(DmaBufFormatModifier(format: drmFormat, modifier: modifier.drmFormatModifier))
        }
    }
    return out
}

/// Build the `VkImageCreateInfo` chain for an imported DRM-modifier DMA-BUF and
/// invoke `body` with a borrowed pointer to the head. The explicit plane-layout
/// array and the external-memory/modifier links stay alive for the call only.
public func withDmaBufImportImageInfo<R>(
    _ descriptor: DmaBufImageDescriptor,
    _ body: (UnsafePointer<VkImageCreateInfo>) -> R
) -> R {
    let layouts = descriptor.planes.map { plane -> VkSubresourceLayout in
        var layout = VkSubresourceLayout()
        layout.offset = plane.offset
        layout.rowPitch = plane.rowPitch
        return layout
    }
    return layouts.withUnsafeBufferPointer { layoutBuffer -> R in
        var modifierInfo = unsafe VkImageDrmFormatModifierExplicitCreateInfoEXT()
        unsafe modifierInfo.sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT
        unsafe modifierInfo.drmFormatModifier = descriptor.modifier
        unsafe modifierInfo.drmFormatModifierPlaneCount = UInt32(descriptor.planes.count)
        unsafe modifierInfo.pPlaneLayouts = layoutBuffer.baseAddress

        return withUnsafePointer(to: &modifierInfo) { modifierPtr -> R in
            var externalInfo = unsafe VkExternalMemoryImageCreateInfo()
            unsafe externalInfo.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
            unsafe externalInfo.pNext = unsafe UnsafeRawPointer(modifierPtr)
            unsafe externalInfo.handleTypes = VK.ExternalMemoryHandleTypeFlags.dmaBufBitEXT.rawValue

            return withUnsafePointer(to: &externalInfo) { externalPtr -> R in
                var info = unsafe VkImageCreateInfo()
                unsafe info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
                unsafe info.pNext = unsafe UnsafeRawPointer(externalPtr)
                let planeFds = descriptor.planes.map { $0.fd >= 0 ? $0.fd : descriptor.fd }
                if Set(planeFds).count > 1 {
                    unsafe info.flags = VK.ImageCreateFlags.disjointBit.rawValue
                }
                unsafe info.imageType = VK_IMAGE_TYPE_2D
                unsafe info.format = vulkanFormatForDrm(descriptor.drmFormat)
                unsafe info.extent = VkExtent3D(width: descriptor.width, height: descriptor.height, depth: 1)
                unsafe info.mipLevels = 1
                unsafe info.arrayLayers = 1
                unsafe info.samples = VK_SAMPLE_COUNT_1_BIT
                unsafe info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
                unsafe info.usage = descriptor.usage.rawValue
                unsafe info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
                unsafe info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
                return withUnsafePointer(to: &info) { unsafe body($0) }
            }
        }
    }
}

/// Import a DMA-BUF as a Vulkan image: create the image with the modifier chain,
/// import the dmabuf fd(s) as dedicated device memory, and bind them. Returns a
/// VkOwned image (which frees the bound memory on destruction via the closure)
/// or nil on any failure. Consumes ownership of every fd in `descriptor` on
/// success or failure.
/// The device owner outlives this table and import is render-thread confined;
/// every stored entry point is validated non-null before construction.
@safe struct DmaBufImportOperations {
    let createImage: PFN_vkCreateImage
    let destroyImage: PFN_vkDestroyImage
    let allocateMemory: PFN_vkAllocateMemory
    let freeMemory: PFN_vkFreeMemory
    let bindImageMemory: PFN_vkBindImageMemory
    let bindImageMemory2: PFN_vkBindImageMemory2
    let getMemoryFdProperties: PFN_vkGetMemoryFdPropertiesKHR
    let getImageMemoryRequirements: PFN_vkGetImageMemoryRequirements
    let getImageMemoryRequirements2: PFN_vkGetImageMemoryRequirements2

    init?(_ dispatch: VK.DeviceDispatch) {
        guard let createImage = unsafe dispatch.vkCreateImage,
              let destroyImage = unsafe dispatch.vkDestroyImage,
              let allocateMemory = unsafe dispatch.vkAllocateMemory,
              let freeMemory = unsafe dispatch.vkFreeMemory,
              let bindImageMemory = unsafe dispatch.vkBindImageMemory,
              let bindImageMemory2 = unsafe dispatch.vkBindImageMemory2,
              let getMemoryFdProperties = unsafe dispatch.vkGetMemoryFdPropertiesKHR,
              let getImageMemoryRequirements =
                unsafe dispatch.vkGetImageMemoryRequirements,
              let getImageMemoryRequirements2 =
                unsafe dispatch.vkGetImageMemoryRequirements2
        else { return nil }
        unsafe self.init(
            createImage: createImage,
            destroyImage: destroyImage,
            allocateMemory: allocateMemory,
            freeMemory: freeMemory,
            bindImageMemory: bindImageMemory,
            bindImageMemory2: bindImageMemory2,
            getMemoryFdProperties: getMemoryFdProperties,
            getImageMemoryRequirements: getImageMemoryRequirements,
            getImageMemoryRequirements2: getImageMemoryRequirements2)
    }

    init(
        createImage: @escaping PFN_vkCreateImage,
        destroyImage: @escaping PFN_vkDestroyImage,
        allocateMemory: @escaping PFN_vkAllocateMemory,
        freeMemory: @escaping PFN_vkFreeMemory,
        bindImageMemory: @escaping PFN_vkBindImageMemory,
        bindImageMemory2: @escaping PFN_vkBindImageMemory2,
        getMemoryFdProperties: @escaping PFN_vkGetMemoryFdPropertiesKHR,
        getImageMemoryRequirements:
            @escaping PFN_vkGetImageMemoryRequirements,
        getImageMemoryRequirements2:
            @escaping PFN_vkGetImageMemoryRequirements2
    ) {
        unsafe self.createImage = unsafe createImage
        unsafe self.destroyImage = unsafe destroyImage
        unsafe self.allocateMemory = unsafe allocateMemory
        unsafe self.freeMemory = unsafe freeMemory
        unsafe self.bindImageMemory = unsafe bindImageMemory
        unsafe self.bindImageMemory2 = unsafe bindImageMemory2
        unsafe self.getMemoryFdProperties = unsafe getMemoryFdProperties
        unsafe self.getImageMemoryRequirements = unsafe getImageMemoryRequirements
        unsafe self.getImageMemoryRequirements2 = unsafe getImageMemoryRequirements2
    }
}

public func importDmaBufImage(
    device: VkDevice,
    dispatch: VK.DeviceDispatch,
    descriptor: DmaBufImageDescriptor
) -> VkOwned<VkImage>? {
    unsafe importDmaBufImage(
        device: device,
        operations: DmaBufImportOperations(dispatch),
        descriptor: descriptor)
}

/// The operation-table overload is intentionally internal. Tests inject Vulkan
/// failures through it without a loader, while production always constructs the
/// table from the generated device dispatch above.
func importDmaBufImage(
    device: VkDevice,
    operations: DmaBufImportOperations?,
    descriptor: DmaBufImageDescriptor
) -> VkOwned<VkImage>? {
    var ownedPlaneFds = descriptor.planes.map { $0.fd >= 0 ? $0.fd : descriptor.fd }
    if ownedPlaneFds.isEmpty { ownedPlaneFds = [descriptor.fd] }
    // Ownership is per *unique fd value*: several planes of one buffer can share a
    // single dmabuf fd (e.g. NV12 packed in one BO), and Vulkan takes ownership of
    // an imported fd exactly once (freeing the bound `VkDeviceMemory` closes it).
    // Track consumption and cleanup by value — never per plane index — so an aliased
    // fd is not closed twice, nor closed after Vulkan already owns it.
    var uniqueOwnedFds = Set(ownedPlaneFds.filter { $0 >= 0 })
    // The contract consumes *every* fd in the descriptor, including the primary
    // `descriptor.fd`. It is already covered whenever a plane defers to it (fd < 0),
    // but a descriptor whose planes all carry explicit fds would otherwise strand a
    // distinct primary fd — track it so cleanup closes it too (the Set dedups the
    // common aliased case, and per-value consume-tracking prevents any double close).
    if descriptor.fd >= 0 { uniqueOwnedFds.insert(descriptor.fd) }
    var consumedFds = Set<Int32>()
    defer {
        for fd in uniqueOwnedFds where !consumedFds.contains(fd) {
            close(fd)
        }
    }

    // A DRM-modifier image has one to three planes. Every plane must resolve to
    // an owned descriptor, and a multi-plane layout must either alias one fd or
    // provide one distinct fd per plane. Partially aliased layouts cannot be
    // represented by the Vulkan disjoint-plane binding model and would attempt
    // to import the same consumed fd twice.
    let distinctPlaneFds = Set(ownedPlaneFds)
    guard descriptor.width > 0,
          descriptor.height > 0,
          vulkanFormatForDrm(descriptor.drmFormat) != VK_FORMAT_UNDEFINED,
          (1...3).contains(descriptor.planes.count),
          ownedPlaneFds.allSatisfy({ $0 >= 0 }),
          distinctPlaneFds.count == 1
            || distinctPlaneFds.count == ownedPlaneFds.count,
          let operations
    else {
        logDmaBufImportFailure(descriptor, "invalid-layout-or-dispatch")
        return nil
    }

    let createImage = unsafe operations.createImage
    let destroyImage = unsafe operations.destroyImage
    let allocateMemory = unsafe operations.allocateMemory
    let freeMemory = unsafe operations.freeMemory
    let bindImageMemory = unsafe operations.bindImageMemory
    let bindImageMemory2 = unsafe operations.bindImageMemory2
    let getMemoryFdProperties = unsafe operations.getMemoryFdProperties
    let getImageMemoryRequirements = unsafe operations.getImageMemoryRequirements
    let getImageMemoryRequirements2 = unsafe operations.getImageMemoryRequirements2

    var image: VkImage? = nil
    let createResult = unsafe withDmaBufImportImageInfo(descriptor) { infoPtr in
        unsafe createImage(device, infoPtr, nil, &image)
    }
    guard createResult == VK_SUCCESS, let image = unsafe image else {
        logDmaBufImportFailure(descriptor, "vkCreateImage-result-\(createResult.rawValue)")
        return nil
    }

    var ok = false
    defer { if !ok { unsafe destroyImage(device, image, nil) } }

    var memories: [VkDeviceMemory] = unsafe []
    // Distinct fds ⇒ each plane imports its own dedicated memory; a shared fd ⇒ one
    // memory covers every plane (imported once, below).
    let separatePlaneMemory = distinctPlaneFds.count > 1

    func allocateImportedMemory(fdIndex: Int, requirements: VkMemoryRequirements) -> VkDeviceMemory? {
        var fdProps = unsafe VkMemoryFdPropertiesKHR()
        unsafe fdProps.sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR
        let fd = ownedPlaneFds[fdIndex]
        let fdPropertiesResult = unsafe getMemoryFdProperties(
            device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, fd, &fdProps)
        guard fdPropertiesResult == VK_SUCCESS else {
            logDmaBufImportFailure(descriptor, "vkGetMemoryFdProperties-result-\(fdPropertiesResult.rawValue)")
            return nil
        }
        let typeBits = unsafe requirements.memoryTypeBits & fdProps.memoryTypeBits
        guard typeBits != 0 else {
            logDmaBufImportFailure(descriptor, "no-compatible-memory-type")
            return nil
        }
        let memoryTypeIndex = UInt32(typeBits.trailingZeroBitCount)

        var dedicated = unsafe VkMemoryDedicatedAllocateInfo()
        unsafe dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
        unsafe dedicated.image = unsafe image

        var memory: VkDeviceMemory? = nil
        let allocated = withUnsafeMutablePointer(to: &dedicated) { dedicatedPtr -> Bool in
            var importInfo = unsafe VkImportMemoryFdInfoKHR()
            unsafe importInfo.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR
            unsafe importInfo.pNext = UnsafeRawPointer(dedicatedPtr)
            unsafe importInfo.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT
            unsafe importInfo.fd = fd
            return withUnsafePointer(to: &importInfo) { importPtr -> Bool in
                var allocInfo = unsafe VkMemoryAllocateInfo()
                unsafe allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
                unsafe allocInfo.pNext = unsafe UnsafeRawPointer(importPtr)
                unsafe allocInfo.allocationSize = requirements.size
                unsafe allocInfo.memoryTypeIndex = memoryTypeIndex
                return unsafe allocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS
            }
        }
        guard allocated, let memory = unsafe memory else {
            logDmaBufImportFailure(descriptor, "vkAllocateMemory")
            return nil
        }
        consumedFds.insert(fd)
        return unsafe memory
    }

    if separatePlaneMemory {
        var binds: [VkBindImageMemoryInfo] = unsafe []
        var planeInfos: [VkBindImagePlaneMemoryInfo] = unsafe []
        for i in descriptor.planes.indices {
            var planeReq = unsafe VkImagePlaneMemoryRequirementsInfo()
            unsafe planeReq.sType = VK_STRUCTURE_TYPE_IMAGE_PLANE_MEMORY_REQUIREMENTS_INFO
            unsafe planeReq.planeAspect = dmaBufPlaneAspect(i)

            var reqInfo = unsafe VkImageMemoryRequirementsInfo2()
            unsafe reqInfo.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2
            unsafe reqInfo.image = unsafe image

            var req2 = unsafe VkMemoryRequirements2()
            unsafe req2.sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2
            withUnsafeMutablePointer(to: &planeReq) { planeReqPtr in
                unsafe reqInfo.pNext = UnsafeRawPointer(planeReqPtr)
                unsafe getImageMemoryRequirements2(device, &reqInfo, &req2)
            }

            guard let memory = unsafe allocateImportedMemory(fdIndex: i, requirements: req2.memoryRequirements) else {
                for unsafe m in unsafe memories { unsafe freeMemory(device, m, nil) }
                return nil
            }
            unsafe memories.append(memory)

            var planeInfo = unsafe VkBindImagePlaneMemoryInfo()
            unsafe planeInfo.sType = VK_STRUCTURE_TYPE_BIND_IMAGE_PLANE_MEMORY_INFO
            unsafe planeInfo.planeAspect = dmaBufPlaneAspect(i)
            unsafe planeInfos.append(planeInfo)

            var bind = unsafe VkBindImageMemoryInfo()
            unsafe bind.sType = VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO
            unsafe bind.image = unsafe image
            unsafe bind.memory = unsafe memory
            unsafe bind.memoryOffset = 0
            unsafe binds.append(bind)
        }
        let bindResult = planeInfos.withUnsafeMutableBufferPointer { planeBuffer in
            for i in unsafe binds.indices {
                unsafe binds[i].pNext = unsafe UnsafeRawPointer(planeBuffer.baseAddress!.advanced(by: i))
            }
            return binds.withUnsafeMutableBufferPointer { bindBuffer in
                unsafe bindImageMemory2(device, UInt32(bindBuffer.count), bindBuffer.baseAddress)
            }
        }
        guard bindResult == VK_SUCCESS else {
            logDmaBufImportFailure(descriptor, "vkBindImageMemory2-result-\(bindResult.rawValue)")
            for unsafe m in unsafe memories { unsafe freeMemory(device, m, nil) }
            return nil
        }
    } else {
        var requirements = VkMemoryRequirements()
        unsafe getImageMemoryRequirements(device, image, &requirements)
        guard let memory = unsafe allocateImportedMemory(fdIndex: 0, requirements: requirements) else {
            return nil
        }
        unsafe memories.append(memory)
        let bindResult = unsafe bindImageMemory(device, image, memory, 0)
        guard bindResult == VK_SUCCESS else {
            logDmaBufImportFailure(descriptor, "vkBindImageMemory-result-\(bindResult.rawValue)")
            for unsafe m in unsafe memories { unsafe freeMemory(device, m, nil) }
            return nil
        }
    }

    guard unsafe !memories.isEmpty else {
        return nil
    }

    ok = true
    return unsafe VkOwned(adopting: image, device: device, destroy: { d, img in
        unsafe destroyImage(d, img, nil)
        for unsafe memory in unsafe memories { unsafe freeMemory(d, memory, nil) }
    })
}

private func dmaBufPlaneAspect(_ index: Int) -> VkImageAspectFlagBits {
    switch index {
    case 0: return VK_IMAGE_ASPECT_PLANE_0_BIT
    case 1: return VK_IMAGE_ASPECT_PLANE_1_BIT
    default: return VK_IMAGE_ASPECT_PLANE_2_BIT
    }
}
