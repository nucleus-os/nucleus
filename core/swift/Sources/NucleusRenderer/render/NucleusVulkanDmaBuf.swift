// Phase 10b.5 — import a DRM-format-modifier DMA-BUF into the Swift Vulkan
// device as a VkImage. Used for both committed Wayland client buffers and the
// GBM scanout BO. The pNext chain assembly (external-memory + explicit DRM
// modifier plane layouts) and live import bind imported memory to the image.

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import VulkanC
import Vulkan

private func logDmaBufImportFailure(_ descriptor: DmaBufImageDescriptor, _ stage: String) {
    #if canImport(Glibc)
    let line = "dmabuf-import: failed stage=\(stage) size=\(descriptor.width)x\(descriptor.height) format=\(descriptor.drmFormat) modifier=\(descriptor.modifier) planes=\(descriptor.planes.count)\n"
    line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
    #endif
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
    /// binds the dst as an input attachment for blending — see 10b.6d) and
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
    pixels: UnsafeRawBufferPointer,
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
    pixels: UnsafeRawBufferPointer,
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
        pixels.count >= sourceCount,
        let source = pixels.baseAddress?.assumingMemoryBound(to: UInt8.self)
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

    let converted = [UInt8](unsafeUninitializedCapacity: destinationCount) {
        destination, initializedCount in
        guard let destinationBase = destination.baseAddress else {
            initializedCount = 0
            return
        }
        for y in 0..<Int(height) {
            let sourceRow = source.advanced(by: y * rowStride)
            let destinationRow = destinationBase.advanced(by: y * destinationRowBytes)
            for x in 0..<Int(width) {
                let sourcePixel = sourceRow.advanced(by: x * 4)
                let destinationPixel = destinationRow.advanced(by: x * 4)
                destinationPixel[0] = sourcePixel[2]
                destinationPixel[1] = sourcePixel[1]
                destinationPixel[2] = sourcePixel[0]
                destinationPixel[3] = opaque ? 255 : sourcePixel[3]
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

/// Map a DRM fourcc to the Vulkan format Skia/the compositor sample it as.
public func vulkanFormatForDrm(_ fourcc: UInt32) -> VkFormat {
    switch fourcc {
    case DrmFourcc.xrgb8888, DrmFourcc.argb8888:
        return VK_FORMAT_B8G8R8A8_UNORM
    default:
        return VK_FORMAT_B8G8R8A8_UNORM
    }
}

/// Query the selected Vulkan physical device for DRM format modifiers that can be
/// sampled as imported client textures. This is the source for
/// zwp_linux_dmabuf feedback; clients should only allocate buffers the renderer's
/// actual Vulkan device says it can sample.
public func querySampleableDmaBufFormats(
    physicalDevice: VkPhysicalDevice,
    instanceDispatch: VK.InstanceDispatch,
    drmFormats: [UInt32] = [DrmFourcc.xrgb8888, DrmFourcc.argb8888]
) -> [DmaBufFormatModifier] {
    guard let getFormatProperties = instanceDispatch.vkGetPhysicalDeviceFormatProperties2,
          let getImageFormatProperties = instanceDispatch.vkGetPhysicalDeviceImageFormatProperties2
    else {
        return []
    }

    var out: [DmaBufFormatModifier] = []
    for drmFormat in drmFormats {
        var list = VkDrmFormatModifierPropertiesList2EXT()
        list.sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_2_EXT

        var props = VkFormatProperties2()
        props.sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2
        withUnsafeMutablePointer(to: &list) { listPtr in
            props.pNext = UnsafeMutableRawPointer(listPtr)
            getFormatProperties(physicalDevice, vulkanFormatForDrm(drmFormat), &props)
        }
        guard list.drmFormatModifierCount > 0 else { continue }

        var modifiers = [VkDrmFormatModifierProperties2EXT](
            repeating: VkDrmFormatModifierProperties2EXT(),
            count: Int(list.drmFormatModifierCount))
        modifiers.withUnsafeMutableBufferPointer { buffer in
            list.pDrmFormatModifierProperties = buffer.baseAddress
            withUnsafeMutablePointer(to: &list) { listPtr in
                props.pNext = UnsafeMutableRawPointer(listPtr)
                getFormatProperties(physicalDevice, vulkanFormatForDrm(drmFormat), &props)
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
            var externalInfo = VkPhysicalDeviceExternalImageFormatInfo()
            externalInfo.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO
            externalInfo.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT

            var modifierInfo = VkPhysicalDeviceImageDrmFormatModifierInfoEXT()
            modifierInfo.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT
            modifierInfo.drmFormatModifier = modifier.drmFormatModifier
            modifierInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE

            var imageInfo = VkPhysicalDeviceImageFormatInfo2()
            imageInfo.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2
            imageInfo.format = vulkanFormatForDrm(drmFormat)
            imageInfo.type = VK_IMAGE_TYPE_2D
            imageInfo.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
            imageInfo.usage = DmaBufImageDescriptor.sampledUsage.rawValue

            var externalProperties = VkExternalImageFormatProperties()
            externalProperties.sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES
            var imageProperties = VkImageFormatProperties2()
            imageProperties.sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2
            let supported = withUnsafePointer(to: &externalInfo) { externalPtr in
                modifierInfo.pNext = UnsafeRawPointer(externalPtr)
                return withUnsafePointer(to: &modifierInfo) { modifierPtr in
                    imageInfo.pNext = UnsafeRawPointer(modifierPtr)
                    return withUnsafeMutablePointer(to: &externalProperties) { externalPropertiesPtr in
                        imageProperties.pNext = UnsafeMutableRawPointer(externalPropertiesPtr)
                        return getImageFormatProperties(physicalDevice, &imageInfo, &imageProperties)
                    }
                }
            }
            guard supported == VK_SUCCESS else { continue }
            let externalFeatures = externalProperties.externalMemoryProperties.externalMemoryFeatures
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
        var modifierInfo = VkImageDrmFormatModifierExplicitCreateInfoEXT()
        modifierInfo.sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT
        modifierInfo.drmFormatModifier = descriptor.modifier
        modifierInfo.drmFormatModifierPlaneCount = UInt32(descriptor.planes.count)
        modifierInfo.pPlaneLayouts = layoutBuffer.baseAddress

        return withUnsafePointer(to: &modifierInfo) { modifierPtr -> R in
            var externalInfo = VkExternalMemoryImageCreateInfo()
            externalInfo.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
            externalInfo.pNext = UnsafeRawPointer(modifierPtr)
            externalInfo.handleTypes = VK.ExternalMemoryHandleTypeFlags.dmaBufBitEXT.rawValue

            return withUnsafePointer(to: &externalInfo) { externalPtr -> R in
                var info = VkImageCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
                info.pNext = UnsafeRawPointer(externalPtr)
                let planeFds = descriptor.planes.map { $0.fd >= 0 ? $0.fd : descriptor.fd }
                if Set(planeFds).count > 1 {
                    info.flags = VK.ImageCreateFlags.disjointBit.rawValue
                }
                info.imageType = VK_IMAGE_TYPE_2D
                info.format = vulkanFormatForDrm(descriptor.drmFormat)
                info.extent = VkExtent3D(width: descriptor.width, height: descriptor.height, depth: 1)
                info.mipLevels = 1
                info.arrayLayers = 1
                info.samples = VK_SAMPLE_COUNT_1_BIT
                info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
                info.usage = descriptor.usage.rawValue
                info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
                info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
                return withUnsafePointer(to: &info) { body($0) }
            }
        }
    }
}

/// Import a DMA-BUF as a Vulkan image: create the image with the modifier chain,
/// import the dmabuf fd(s) as dedicated device memory, and bind them. Returns a
/// VkOwned image (which frees the bound memory on destruction via the closure)
/// or nil on any failure. Consumes ownership of every fd in `descriptor` on
/// success or failure.
struct DmaBufImportOperations {
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
        guard let createImage = dispatch.vkCreateImage,
              let destroyImage = dispatch.vkDestroyImage,
              let allocateMemory = dispatch.vkAllocateMemory,
              let freeMemory = dispatch.vkFreeMemory,
              let bindImageMemory = dispatch.vkBindImageMemory,
              let bindImageMemory2 = dispatch.vkBindImageMemory2,
              let getMemoryFdProperties = dispatch.vkGetMemoryFdPropertiesKHR,
              let getImageMemoryRequirements =
                dispatch.vkGetImageMemoryRequirements,
              let getImageMemoryRequirements2 =
                dispatch.vkGetImageMemoryRequirements2
        else { return nil }
        self.init(
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
        self.createImage = createImage
        self.destroyImage = destroyImage
        self.allocateMemory = allocateMemory
        self.freeMemory = freeMemory
        self.bindImageMemory = bindImageMemory
        self.bindImageMemory2 = bindImageMemory2
        self.getMemoryFdProperties = getMemoryFdProperties
        self.getImageMemoryRequirements = getImageMemoryRequirements
        self.getImageMemoryRequirements2 = getImageMemoryRequirements2
    }
}

public func importDmaBufImage(
    device: VkDevice,
    dispatch: VK.DeviceDispatch,
    descriptor: DmaBufImageDescriptor
) -> VkOwned<VkImage>? {
    importDmaBufImage(
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
          (1...3).contains(descriptor.planes.count),
          ownedPlaneFds.allSatisfy({ $0 >= 0 }),
          distinctPlaneFds.count == 1
            || distinctPlaneFds.count == ownedPlaneFds.count,
          let operations
    else {
        logDmaBufImportFailure(descriptor, "invalid-layout-or-dispatch")
        return nil
    }

    let createImage = operations.createImage
    let destroyImage = operations.destroyImage
    let allocateMemory = operations.allocateMemory
    let freeMemory = operations.freeMemory
    let bindImageMemory = operations.bindImageMemory
    let bindImageMemory2 = operations.bindImageMemory2
    let getMemoryFdProperties = operations.getMemoryFdProperties
    let getImageMemoryRequirements = operations.getImageMemoryRequirements
    let getImageMemoryRequirements2 = operations.getImageMemoryRequirements2

    var image: VkImage? = nil
    let createResult = withDmaBufImportImageInfo(descriptor) { infoPtr in
        createImage(device, infoPtr, nil, &image)
    }
    guard createResult == VK_SUCCESS, let image else {
        logDmaBufImportFailure(descriptor, "vkCreateImage-result-\(createResult.rawValue)")
        return nil
    }

    var ok = false
    defer { if !ok { destroyImage(device, image, nil) } }

    var memories: [VkDeviceMemory] = []
    // Distinct fds ⇒ each plane imports its own dedicated memory; a shared fd ⇒ one
    // memory covers every plane (imported once, below).
    let separatePlaneMemory = distinctPlaneFds.count > 1

    func allocateImportedMemory(fdIndex: Int, requirements: VkMemoryRequirements) -> VkDeviceMemory? {
        var fdProps = VkMemoryFdPropertiesKHR()
        fdProps.sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR
        let fd = ownedPlaneFds[fdIndex]
        let fdPropertiesResult = getMemoryFdProperties(
            device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, fd, &fdProps)
        guard fdPropertiesResult == VK_SUCCESS else {
            logDmaBufImportFailure(descriptor, "vkGetMemoryFdProperties-result-\(fdPropertiesResult.rawValue)")
            return nil
        }
        let typeBits = requirements.memoryTypeBits & fdProps.memoryTypeBits
        guard typeBits != 0 else {
            logDmaBufImportFailure(descriptor, "no-compatible-memory-type")
            return nil
        }
        let memoryTypeIndex = UInt32(typeBits.trailingZeroBitCount)

        var dedicated = VkMemoryDedicatedAllocateInfo()
        dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
        dedicated.image = image

        var memory: VkDeviceMemory? = nil
        let allocated = withUnsafeMutablePointer(to: &dedicated) { dedicatedPtr -> Bool in
            var importInfo = VkImportMemoryFdInfoKHR()
            importInfo.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR
            importInfo.pNext = UnsafeRawPointer(dedicatedPtr)
            importInfo.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT
            importInfo.fd = fd
            return withUnsafePointer(to: &importInfo) { importPtr -> Bool in
                var allocInfo = VkMemoryAllocateInfo()
                allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
                allocInfo.pNext = UnsafeRawPointer(importPtr)
                allocInfo.allocationSize = requirements.size
                allocInfo.memoryTypeIndex = memoryTypeIndex
                return allocateMemory(device, &allocInfo, nil, &memory) == VK_SUCCESS
            }
        }
        guard allocated, let memory else {
            logDmaBufImportFailure(descriptor, "vkAllocateMemory")
            return nil
        }
        consumedFds.insert(fd)
        return memory
    }

    if separatePlaneMemory {
        var binds: [VkBindImageMemoryInfo] = []
        var planeInfos: [VkBindImagePlaneMemoryInfo] = []
        for i in descriptor.planes.indices {
            var planeReq = VkImagePlaneMemoryRequirementsInfo()
            planeReq.sType = VK_STRUCTURE_TYPE_IMAGE_PLANE_MEMORY_REQUIREMENTS_INFO
            planeReq.planeAspect = dmaBufPlaneAspect(i)

            var reqInfo = VkImageMemoryRequirementsInfo2()
            reqInfo.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2
            reqInfo.image = image

            var req2 = VkMemoryRequirements2()
            req2.sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2
            withUnsafeMutablePointer(to: &planeReq) { planeReqPtr in
                reqInfo.pNext = UnsafeRawPointer(planeReqPtr)
                getImageMemoryRequirements2(device, &reqInfo, &req2)
            }

            guard let memory = allocateImportedMemory(fdIndex: i, requirements: req2.memoryRequirements) else {
                for m in memories { freeMemory(device, m, nil) }
                return nil
            }
            memories.append(memory)

            var planeInfo = VkBindImagePlaneMemoryInfo()
            planeInfo.sType = VK_STRUCTURE_TYPE_BIND_IMAGE_PLANE_MEMORY_INFO
            planeInfo.planeAspect = dmaBufPlaneAspect(i)
            planeInfos.append(planeInfo)

            var bind = VkBindImageMemoryInfo()
            bind.sType = VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO
            bind.image = image
            bind.memory = memory
            bind.memoryOffset = 0
            binds.append(bind)
        }
        let bindResult = planeInfos.withUnsafeMutableBufferPointer { planeBuffer in
            for i in binds.indices {
                binds[i].pNext = UnsafeRawPointer(planeBuffer.baseAddress!.advanced(by: i))
            }
            return binds.withUnsafeMutableBufferPointer { bindBuffer in
                bindImageMemory2(device, UInt32(bindBuffer.count), bindBuffer.baseAddress)
            }
        }
        guard bindResult == VK_SUCCESS else {
            logDmaBufImportFailure(descriptor, "vkBindImageMemory2-result-\(bindResult.rawValue)")
            for m in memories { freeMemory(device, m, nil) }
            return nil
        }
    } else {
        var requirements = VkMemoryRequirements()
        getImageMemoryRequirements(device, image, &requirements)
        guard let memory = allocateImportedMemory(fdIndex: 0, requirements: requirements) else {
            return nil
        }
        memories.append(memory)
        let bindResult = bindImageMemory(device, image, memory, 0)
        guard bindResult == VK_SUCCESS else {
            logDmaBufImportFailure(descriptor, "vkBindImageMemory-result-\(bindResult.rawValue)")
            for m in memories { freeMemory(device, m, nil) }
            return nil
        }
    }

    guard !memories.isEmpty else {
        return nil
    }

    ok = true
    return VkOwned(adopting: image, device: device, destroy: { d, img in
        destroyImage(d, img, nil)
        for memory in memories { freeMemory(d, memory, nil) }
    })
}

private func dmaBufPlaneAspect(_ index: Int) -> VkImageAspectFlagBits {
    switch index {
    case 0: return VK_IMAGE_ASPECT_PLANE_0_BIT
    case 1: return VK_IMAGE_ASPECT_PLANE_1_BIT
    default: return VK_IMAGE_ASPECT_PLANE_2_BIT
    }
}
