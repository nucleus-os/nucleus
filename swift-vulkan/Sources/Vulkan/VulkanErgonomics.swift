// Hand-written ergonomic helpers layered on the generated Vulkan binding.
// These are generic Swift-Vulkan utilities — not tied to any particular
// application's instance/device creation contracts.

public import VulkanC

// MARK: - Base dispatch bootstrap

extension VK {
    /// Bootstrap the base dispatch table from the process-linked
    /// `vkGetInstanceProcAddr` exported by the Vulkan loader. Declared in the VK
    /// scope (not BaseDispatch) so the loader symbol is not shadowed by the
    /// stored property of the same name.
    public static func loadBaseDispatch() -> BaseDispatch {
        unsafe BaseDispatch(loader: vkGetInstanceProcAddr)
    }
}

// MARK: - Two-call enumeration

/// Checked driver for Vulkan's two-call enumerate protocol: query the count,
/// size storage, fill, and retry on `VK_INCOMPLETE` (the set grew between
/// calls). Returns nil on a hard error, `[]` when the count is zero.
public enum VkEnumerate {
    public static func array<T>(
        _ body: (_ count: UnsafeMutablePointer<UInt32>, _ out: UnsafeMutablePointer<T>?) -> VkResult
    ) -> [T]? {
        while true {
            var count: UInt32 = 0
            guard unsafe body(&count, nil) == VK_SUCCESS else { return nil }
            if count == 0 { return [] }

            var lastResult = VK_SUCCESS
            let items = unsafe [T](unsafeUninitializedCapacity: Int(count)) {
                buffer, initialized in
                var n = count
                lastResult = unsafe body(&n, buffer.baseAddress)
                initialized = (lastResult == VK_SUCCESS) ? Int(n) : 0
            }
            switch lastResult {
            case VK_SUCCESS: return items
            case VK_INCOMPLETE: continue // grew between the count and fill calls
            default: return nil
            }
        }
    }
}

// MARK: - C-string array borrowing

/// Borrow a `[String]` as a count-delimited table of pointers to NUL-terminated
/// C strings for the duration of `body`. Every CString stays alive through the
/// nested `withCString` scopes; no pointer escapes the call. Vulkan contracts
/// carry an explicit count, so the pointer table itself has no trailing sentinel.
@unsafe public func withCStringArray<R>(
    _ strings: [String],
    _ body: (_ pointers: UnsafePointer<UnsafePointer<CChar>?>?, _ count: UInt32) -> R
) -> R {
    guard !strings.isEmpty else { return body(nil, 0) }
    precondition(strings.count <= Int(UInt32.max), "Vulkan string array exceeds UInt32 capacity")

    func recurse(
        _ index: Int,
        _ pointers: inout OutputSpan<UnsafePointer<CChar>?>
    ) -> R {
        if index == strings.count {
            return unsafe pointers.span.withUnsafeBufferPointer { buffer in
                unsafe body(buffer.baseAddress, UInt32(buffer.count))
            }
        }
        return strings[index].withCString { pointer in
            unsafe pointers.append(pointer)
            return unsafe recurse(index + 1, &pointers)
        }
    }

    return unsafe withTemporaryAllocation(
        of: UnsafePointer<CChar>?.self,
        capacity: strings.count
    ) { pointers in
        unsafe recurse(0, &pointers)
    }
}

// MARK: - Owned device-child handle

/// A noncopyable owner for a device-child handle. The destroy closure wraps the
/// typed `PFN_vkDestroy*`; `deinit` runs it once, `take()` suppresses it.
/// The owner never dereferences either opaque handle. Its caller must arrange
/// Vulkan-required external synchronization while constructing or destroying it.
@safe public struct VkOwned<Handle>: ~Copyable {
    public let handle: Handle
    private let device: VkDevice
    private let destroyer: (VkDevice, Handle) -> Void

    public init(adopting handle: Handle, device: VkDevice, destroy: @escaping (VkDevice, Handle) -> Void) {
        self.handle = handle
        unsafe self.device = device
        unsafe self.destroyer = destroy
    }

    deinit { unsafe destroyer(device, handle) }
}

// MARK: - Owned-image box

/// A reference-type box that holds a `~Copyable` `VkOwned<VkImage>` so it can be
/// captured by an `@escaping` destroy closure (and live in maps keyed by id).
/// `release()` drops the held image exactly once (idempotent);
/// `deinit` drops it if `release()` was never called.
/// Encapsulates the unsafe image handle inside `VkOwned`; no raw handle escapes.
///
/// Prefer `take()` over `release()` wherever the image outlives the box: moving
/// the owner out restores static single-ownership, whereas a shared box only
/// promises single destruction by convention.
@safe public final class VkOwnedImageBox {
    private var image: VkOwned<VkImage>?
    public init(consuming image: consuming VkOwned<VkImage>) {
        unsafe self.image = consume image
    }
    /// Move the held image owner out of the box, transferring destruction duty to
    /// the caller. The box is empty afterward, so any later `release()`/`deinit`
    /// — including one reached through another reference to this same box — is a
    /// no-op rather than a second destroy.
    public func take() -> VkOwned<VkImage>? { unsafe image.take() }
    /// Drop the held image now (runs its `deinit`). Safe to call once.
    public func release() { unsafe image = nil }
    deinit { unsafe image = nil }
}

// MARK: - Device-child resource constructors

extension VK.DeviceDispatch {
    public func createFence(_ device: VkDevice, signaled: Bool = false) -> VkOwned<VkFence>? {
        guard let create = unsafe vkCreateFence,
              let destroy = unsafe vkDestroyFence
        else { return nil }
        var ci = unsafe VkFenceCreateInfo()
        unsafe ci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        unsafe ci.flags = signaled ? VK.FenceCreateFlags.signaledBit.rawValue : 0
        var h: VkFence? = nil
        guard unsafe create(device, &ci, nil, &h) == VK_SUCCESS else { return nil }
        guard let h = unsafe h else { return nil }
        return unsafe VkOwned(
            adopting: h,
            device: device,
            destroy: { d, x in unsafe destroy(d, x, nil) })
    }

    public func createSemaphore(_ device: VkDevice) -> VkOwned<VkSemaphore>? {
        guard let create = unsafe vkCreateSemaphore,
              let destroy = unsafe vkDestroySemaphore
        else { return nil }
        var ci = unsafe VkSemaphoreCreateInfo()
        unsafe ci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var h: VkSemaphore? = nil
        guard unsafe create(device, &ci, nil, &h) == VK_SUCCESS else { return nil }
        guard let h = unsafe h else { return nil }
        return unsafe VkOwned(
            adopting: h,
            device: device,
            destroy: { d, x in unsafe destroy(d, x, nil) })
    }

    public func createCommandPool(_ device: VkDevice, queueFamily: UInt32) -> VkOwned<VkCommandPool>? {
        guard let create = unsafe vkCreateCommandPool,
              let destroy = unsafe vkDestroyCommandPool
        else { return nil }
        var ci = unsafe VkCommandPoolCreateInfo()
        unsafe ci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        unsafe ci.queueFamilyIndex = queueFamily
        unsafe ci.flags = VK.CommandPoolCreateFlags.resetCommandBufferBit.rawValue
        var h: VkCommandPool? = nil
        guard unsafe create(device, &ci, nil, &h) == VK_SUCCESS else { return nil }
        guard let h = unsafe h else { return nil }
        return unsafe VkOwned(
            adopting: h,
            device: device,
            destroy: { d, x in unsafe destroy(d, x, nil) })
    }

    public func allocateMemory(_ device: VkDevice, info: VkMemoryAllocateInfo) -> VkOwned<VkDeviceMemory>? {
        guard let allocate = unsafe vkAllocateMemory,
              let free = unsafe vkFreeMemory
        else { return nil }
        var ci = unsafe info
        unsafe ci.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        var h: VkDeviceMemory? = nil
        guard unsafe allocate(device, &ci, nil, &h) == VK_SUCCESS else { return nil }
        guard let h = unsafe h else { return nil }
        return unsafe VkOwned(
            adopting: h,
            device: device,
            destroy: { d, x in unsafe free(d, x, nil) })
    }

    public func createBuffer(_ device: VkDevice, info: VkBufferCreateInfo) -> VkOwned<VkBuffer>? {
        guard let create = unsafe vkCreateBuffer,
              let destroy = unsafe vkDestroyBuffer
        else { return nil }
        var ci = unsafe info
        unsafe ci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        var h: VkBuffer? = nil
        guard unsafe create(device, &ci, nil, &h) == VK_SUCCESS else { return nil }
        guard let h = unsafe h else { return nil }
        return unsafe VkOwned(
            adopting: h,
            device: device,
            destroy: { d, x in unsafe destroy(d, x, nil) })
    }

    public func createImage(_ device: VkDevice, info: VkImageCreateInfo) -> VkOwned<VkImage>? {
        guard let create = unsafe vkCreateImage,
              let destroy = unsafe vkDestroyImage
        else { return nil }
        var ci = unsafe info
        unsafe ci.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        var h: VkImage? = nil
        guard unsafe create(device, &ci, nil, &h) == VK_SUCCESS else { return nil }
        guard let h = unsafe h else { return nil }
        return unsafe VkOwned(
            adopting: h,
            device: device,
            destroy: { d, x in unsafe destroy(d, x, nil) })
    }

    public func createImageView(_ device: VkDevice, info: VkImageViewCreateInfo) -> VkOwned<VkImageView>? {
        guard let create = unsafe vkCreateImageView,
              let destroy = unsafe vkDestroyImageView
        else { return nil }
        var ci = unsafe info
        unsafe ci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        var h: VkImageView? = nil
        guard unsafe create(device, &ci, nil, &h) == VK_SUCCESS else { return nil }
        guard let h = unsafe h else { return nil }
        return unsafe VkOwned(
            adopting: h,
            device: device,
            destroy: { d, x in unsafe destroy(d, x, nil) })
    }

    public func createDescriptorPool(_ device: VkDevice, info: VkDescriptorPoolCreateInfo) -> VkOwned<VkDescriptorPool>? {
        guard let create = unsafe vkCreateDescriptorPool,
              let destroy = unsafe vkDestroyDescriptorPool
        else { return nil }
        var ci = unsafe info
        unsafe ci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        var h: VkDescriptorPool? = nil
        guard unsafe create(device, &ci, nil, &h) == VK_SUCCESS else { return nil }
        guard let h = unsafe h else { return nil }
        return unsafe VkOwned(
            adopting: h,
            device: device,
            destroy: { d, x in unsafe destroy(d, x, nil) })
    }

    public func createPipelineLayout(_ device: VkDevice, info: VkPipelineLayoutCreateInfo) -> VkOwned<VkPipelineLayout>? {
        guard let create = unsafe vkCreatePipelineLayout,
              let destroy = unsafe vkDestroyPipelineLayout
        else { return nil }
        var ci = unsafe info
        unsafe ci.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        var h: VkPipelineLayout? = nil
        guard unsafe create(device, &ci, nil, &h) == VK_SUCCESS else { return nil }
        guard let h = unsafe h else { return nil }
        return unsafe VkOwned(
            adopting: h,
            device: device,
            destroy: { d, x in unsafe destroy(d, x, nil) })
    }
}
