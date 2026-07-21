import NucleusSkiaGraphiteBridge
import VulkanC
import Vulkan
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// Owns one imported client acquire semaphore. The sync fd is consumed on
/// every initializer path and the Vulkan semaphore is destroyed exactly once.
final class ClientAcquireSemaphore {
    let semaphore: VkSemaphore
    private let device: VkDevice
    private let dispatch: VK.DeviceDispatch

    init?(
        device: VkDevice,
        dispatch: VK.DeviceDispatch,
        consumingSyncFd fd: Int32
    ) {
        guard fd >= 0, let create = dispatch.vkCreateSemaphore,
              let importFd = dispatch.vkImportSemaphoreFdKHR
        else {
            if fd >= 0 { close(fd) }
            return nil
        }
        var info = VkSemaphoreCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var created: VkSemaphore?
        guard create(device, &info, nil, &created) == VK_SUCCESS,
              let created
        else {
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
        semaphore = created
    }

    deinit {
        dispatch.vkDestroySemaphore?(device, semaphore, nil)
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
