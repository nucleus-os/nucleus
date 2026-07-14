// Hand-written ergonomic helpers layered on the generated Vulkan binding.
// These are generic Swift-Vulkan utilities — not tied to any particular
// application's instance/device creation contracts.

import VulkanC

// MARK: - Base dispatch bootstrap

extension VK {
    /// Bootstrap the base dispatch table from the process-linked
    /// `vkGetInstanceProcAddr` exported by the Vulkan loader. Declared in the VK
    /// scope (not BaseDispatch) so the loader symbol is not shadowed by the
    /// stored property of the same name.
    public static func loadBaseDispatch() -> BaseDispatch {
        BaseDispatch(loader: vkGetInstanceProcAddr)
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
            guard body(&count, nil) == VK_SUCCESS else { return nil }
            if count == 0 { return [] }

            var lastResult = VK_SUCCESS
            let items = [T](unsafeUninitializedCapacity: Int(count)) { buffer, initialized in
                var n = count
                lastResult = body(&n, buffer.baseAddress)
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

/// Borrow a `[String]` as a NUL-terminated C string array for the duration of
/// `body`. Every CString stays alive through the nested `withCString` scopes; no
/// pointer escapes the call.
public func withCStringArray<R>(
    _ strings: [String],
    _ body: (_ pointers: UnsafePointer<UnsafePointer<CChar>?>?, _ count: UInt32) -> R
) -> R {
    func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>?]) -> R {
        if index == strings.count {
            if acc.isEmpty { return body(nil, 0) }
            return acc.withUnsafeBufferPointer { buf in body(buf.baseAddress, UInt32(acc.count)) }
        }
        return strings[index].withCString { c in recurse(index + 1, acc + [c]) }
    }
    return recurse(0, [])
}

// MARK: - Owned device-child handle

/// A noncopyable owner for a device-child handle. The destroy closure wraps the
/// typed `PFN_vkDestroy*`; `deinit` runs it once, `take()` suppresses it.
public struct VkOwned<Handle>: ~Copyable {
    public let handle: Handle
    private let device: VkDevice
    private let destroyer: (VkDevice, Handle) -> Void

    public init(adopting handle: Handle, device: VkDevice, destroy: @escaping (VkDevice, Handle) -> Void) {
        self.handle = handle
        self.device = device
        self.destroyer = destroy
    }

    deinit { destroyer(device, handle) }
}

// MARK: - Owned-image box

/// A reference-type box that holds a `~Copyable` `VkOwned<VkImage>` so it can be
/// captured by an `@escaping` destroy closure (and live in maps keyed by id).
/// `release()` drops the held image exactly once (idempotent);
/// `deinit` drops it if `release()` was never called.
public final class VkOwnedImageBox {
    private var image: VkOwned<VkImage>?
    public init(consuming image: consuming VkOwned<VkImage>) { self.image = consume image }
    /// Drop the held image now (runs its `deinit`). Safe to call once.
    public func release() { image = nil }
    deinit { image = nil }
}

// MARK: - Device-child resource constructors

extension VK.DeviceDispatch {
    public func createFence(_ device: VkDevice, signaled: Bool = false) -> VkOwned<VkFence>? {
        guard let create = vkCreateFence, let destroy = vkDestroyFence else { return nil }
        var ci = VkFenceCreateInfo()
        ci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        ci.flags = signaled ? VK.FenceCreateFlags.signaledBit.rawValue : 0
        var h: VkFence? = nil
        guard create(device, &ci, nil, &h) == VK_SUCCESS, let h else { return nil }
        return VkOwned(adopting: h, device: device, destroy: { d, x in destroy(d, x, nil) })
    }

    public func createSemaphore(_ device: VkDevice) -> VkOwned<VkSemaphore>? {
        guard let create = vkCreateSemaphore, let destroy = vkDestroySemaphore else { return nil }
        var ci = VkSemaphoreCreateInfo()
        ci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var h: VkSemaphore? = nil
        guard create(device, &ci, nil, &h) == VK_SUCCESS, let h else { return nil }
        return VkOwned(adopting: h, device: device, destroy: { d, x in destroy(d, x, nil) })
    }

    public func createCommandPool(_ device: VkDevice, queueFamily: UInt32) -> VkOwned<VkCommandPool>? {
        guard let create = vkCreateCommandPool, let destroy = vkDestroyCommandPool else { return nil }
        var ci = VkCommandPoolCreateInfo()
        ci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        ci.queueFamilyIndex = queueFamily
        ci.flags = VK.CommandPoolCreateFlags.resetCommandBufferBit.rawValue
        var h: VkCommandPool? = nil
        guard create(device, &ci, nil, &h) == VK_SUCCESS, let h else { return nil }
        return VkOwned(adopting: h, device: device, destroy: { d, x in destroy(d, x, nil) })
    }

    public func allocateMemory(_ device: VkDevice, info: VkMemoryAllocateInfo) -> VkOwned<VkDeviceMemory>? {
        guard let allocate = vkAllocateMemory, let free = vkFreeMemory else { return nil }
        var ci = info
        ci.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        var h: VkDeviceMemory? = nil
        guard allocate(device, &ci, nil, &h) == VK_SUCCESS, let h else { return nil }
        return VkOwned(adopting: h, device: device, destroy: { d, x in free(d, x, nil) })
    }

    public func createBuffer(_ device: VkDevice, info: VkBufferCreateInfo) -> VkOwned<VkBuffer>? {
        guard let create = vkCreateBuffer, let destroy = vkDestroyBuffer else { return nil }
        var ci = info
        ci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        var h: VkBuffer? = nil
        guard create(device, &ci, nil, &h) == VK_SUCCESS, let h else { return nil }
        return VkOwned(adopting: h, device: device, destroy: { d, x in destroy(d, x, nil) })
    }

    public func createImage(_ device: VkDevice, info: VkImageCreateInfo) -> VkOwned<VkImage>? {
        guard let create = vkCreateImage, let destroy = vkDestroyImage else { return nil }
        var ci = info
        ci.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        var h: VkImage? = nil
        guard create(device, &ci, nil, &h) == VK_SUCCESS, let h else { return nil }
        return VkOwned(adopting: h, device: device, destroy: { d, x in destroy(d, x, nil) })
    }

    public func createImageView(_ device: VkDevice, info: VkImageViewCreateInfo) -> VkOwned<VkImageView>? {
        guard let create = vkCreateImageView, let destroy = vkDestroyImageView else { return nil }
        var ci = info
        ci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        var h: VkImageView? = nil
        guard create(device, &ci, nil, &h) == VK_SUCCESS, let h else { return nil }
        return VkOwned(adopting: h, device: device, destroy: { d, x in destroy(d, x, nil) })
    }

    public func createDescriptorPool(_ device: VkDevice, info: VkDescriptorPoolCreateInfo) -> VkOwned<VkDescriptorPool>? {
        guard let create = vkCreateDescriptorPool, let destroy = vkDestroyDescriptorPool else { return nil }
        var ci = info
        ci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        var h: VkDescriptorPool? = nil
        guard create(device, &ci, nil, &h) == VK_SUCCESS, let h else { return nil }
        return VkOwned(adopting: h, device: device, destroy: { d, x in destroy(d, x, nil) })
    }

    public func createPipelineLayout(_ device: VkDevice, info: VkPipelineLayoutCreateInfo) -> VkOwned<VkPipelineLayout>? {
        guard let create = vkCreatePipelineLayout, let destroy = vkDestroyPipelineLayout else { return nil }
        var ci = info
        ci.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        var h: VkPipelineLayout? = nil
        guard create(device, &ci, nil, &h) == VK_SUCCESS, let h else { return nil }
        return VkOwned(adopting: h, device: device, destroy: { d, x in destroy(d, x, nil) })
    }
}
