import NucleusSkiaGraphiteBridge
import Vulkan
import VulkanC

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// Owns one imported client acquire semaphore. The sync fd is consumed on
/// every initializer path and the Vulkan semaphore is destroyed exactly once.
/// The render actor serializes use; this owner consumes the sync fd and keeps
/// the device alive until the imported semaphore is destroyed.
@safe final class ClientAcquireSemaphore {
    let semaphore: VkSemaphore
    private let device: VkDevice
    private let dispatch: VK.DeviceDispatch

    init?(
        device: VkDevice,
        dispatch: VK.DeviceDispatch,
        consumingSyncFd fd: Int32
    ) {
        guard fd >= 0, let create = unsafe dispatch.vkCreateSemaphore,
            let importFd = unsafe dispatch.vkImportSemaphoreFdKHR
        else {
            if fd >= 0 { close(fd) }
            return nil
        }
        var info = unsafe VkSemaphoreCreateInfo()
        unsafe info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var created: VkSemaphore?
        guard unsafe create(device, &info, nil, &created) == VK_SUCCESS,
            let created = unsafe created
        else {
            close(fd)
            return nil
        }
        var importInfo = unsafe VkImportSemaphoreFdInfoKHR()
        unsafe importInfo.sType = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR
        unsafe importInfo.semaphore = created
        unsafe importInfo.flags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT.rawValue
        unsafe importInfo.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT
        unsafe importInfo.fd = fd
        guard unsafe importFd(device, &importInfo) == VK_SUCCESS else {
            unsafe dispatch.vkDestroySemaphore?(device, created, nil)
            close(fd)
            return nil
        }
        unsafe self.device = device
        self.dispatch = dispatch
        unsafe semaphore = created
    }

    deinit {
        unsafe dispatch.vkDestroySemaphore?(device, semaphore, nil)
    }
}

struct PendingShmUpload: Equatable {
    var pixels: [UInt8]
    var width: Int32
    var height: Int32
    var generation: UInt64
}

/// Last-writer-wins queue keyed by stable client texture id. At most one owned
/// converted buffer exists per surface while the renderer is busy.
struct PendingShmUploadQueue {
    private var entries: [UInt64: PendingShmUpload] = [:]
    private(set) var byteCount: UInt64 = 0
    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    mutating func enqueue(_ upload: PendingShmUpload, for id: UInt64) -> Bool {
        let replaced = entries[id] != nil
        if let old = entries[id] {
            byteCount &-= UInt64(old.pixels.count)
        }
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
