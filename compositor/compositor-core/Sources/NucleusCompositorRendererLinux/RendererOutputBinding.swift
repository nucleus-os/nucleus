import Glibc
import NucleusCompositorDrmC
internal import NucleusRenderer
internal import Vulkan
internal import VulkanC

/// Owns a diagnostic duplicate of a sync_file. The live synchronization fd is
/// consumed by Vulkan or KMS; this duplicate exists only for telemetry.
final class DiagnosticSyncFile {
    private var fd: Int32

    init?(duplicating sourceFd: Int32) {
        guard sourceFd >= 0 else { return nil }
        let copied = dup(sourceFd)
        guard copied >= 0 else { return nil }
        fd = copied
    }

    func signalTimestampNs() -> UInt64? {
        var snapshot = nucleus_drm_sync_file_snapshot()
        guard unsafe nucleus_drm_get_sync_file_snapshot(fd, &snapshot) == 0,
            snapshot.status > 0, snapshot.latest_timestamp_ns > 0
        else { return nil }
        return snapshot.latest_timestamp_ns
    }

    deinit {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

/// One scanout-ring slot and its strict framebuffer/image/BO lifetime owner.
@safe final class ScanoutSlot {
    let imageHandle: VkImage
    let fbId: UInt32
    private var owner: OutputBufferOwner?

    init(imageHandle: VkImage, fbId: UInt32, owner: consuming OutputBufferOwner) {
        unsafe self.imageHandle = imageHandle
        self.fbId = fbId
        self.owner = consume owner
    }

    func release() { owner = nil }
    deinit { owner = nil }
}

/// Exportable Vulkan completion semaphore retained through KMS presentation.
@safe final class DrmRenderSync {
    let semaphore: VkSemaphore
    private let device: VkDevice
    private let dispatch: VK.DeviceDispatch
    private(set) var syncFd: Int32 = -1
    var submissionSerial: UInt64 = 0
    private var renderFenceDiagnostic: DiagnosticSyncFile?
    private var clientAcquireFenceDiagnostics: [DiagnosticSyncFile] = []

    init?(device: VkDevice, dispatch: VK.DeviceDispatch) {
        guard let create = unsafe dispatch.vkCreateSemaphore else { return nil }
        var export = unsafe VkExportSemaphoreCreateInfo()
        unsafe export.sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO
        unsafe export.handleTypes = VkExternalSemaphoreHandleTypeFlags(
            VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT.rawValue)
        var info = unsafe VkSemaphoreCreateInfo()
        unsafe info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var created: VkSemaphore? = nil
        let result = withUnsafePointer(to: &export) { exportPointer in
            unsafe info.pNext = UnsafeRawPointer(exportPointer)
            return unsafe create(device, &info, nil, &created)
        }
        guard result == VK_SUCCESS, let created = unsafe created else { return nil }
        unsafe self.device = device
        self.dispatch = dispatch
        unsafe self.semaphore = created
    }

    func exportSyncFd() -> Bool {
        guard syncFd < 0,
            let getFd = unsafe dispatch.vkGetSemaphoreFdKHR
        else {
            return false
        }
        var info = unsafe VkSemaphoreGetFdInfoKHR()
        unsafe info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR
        unsafe info.semaphore = semaphore
        unsafe info.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT
        var fd: Int32 = -1
        guard unsafe getFd(device, &info, &fd) == VK_SUCCESS, fd >= 0 else {
            return false
        }
        syncFd = fd
        renderFenceDiagnostic = DiagnosticSyncFile(duplicating: fd)
        return true
    }

    func attachClientAcquireFenceDiagnostics(
        _ diagnostics: [DiagnosticSyncFile]
    ) {
        clientAcquireFenceDiagnostics = diagnostics
    }

    func takeFenceTelemetry() -> CompositeFenceTelemetry {
        var telemetry = CompositeFenceTelemetry()
        telemetry.clientAcquireFenceCount =
            UInt64(clientAcquireFenceDiagnostics.count)
        telemetry.latestClientAcquireSignalNs =
            clientAcquireFenceDiagnostics.compactMap {
                $0.signalTimestampNs()
            }.max()
        telemetry.renderCompleteNs = renderFenceDiagnostic?.signalTimestampNs()
        clientAcquireFenceDiagnostics.removeAll()
        renderFenceDiagnostic = nil
        return telemetry
    }

    func closeSyncFd() {
        if syncFd >= 0 {
            close(syncFd)
            syncFd = -1
        }
    }

    deinit {
        closeSyncFd()
        unsafe dispatch.vkDestroySemaphore?(device, semaphore, nil)
    }
}

/// Retained by DrmOutput while its atomic flip is pending.
@safe final class SubmittedCompositeScanout {
    let slot: ScanoutSlot
    let sync: DrmRenderSync

    init(slot: ScanoutSlot, sync: DrmRenderSync) {
        self.slot = slot
        self.sync = sync
    }
}

/// All KMS, scanout-ring, cursor, and in-flight state owned by one output
/// topology generation.
@safe final class RenderOutputBinding {
    let outputId: UInt64
    let generation: UInt64
    let drm: DrmOutput
    let slots: [ScanoutSlot]
    let format: VkFormat
    let queueFamily: UInt32
    let width: Int32
    let height: Int32
    let logicalRect: OutputRect
    let fractionalScale: Double
    var cursorPlane: DrmCursorPlane?
    var currentSlot: ScanoutSlot?
    var currentRenderSync: DrmRenderSync?
    var pendingRenderSync: DrmRenderSync?
    var pendingSubmissionSerial: UInt64 = 0
    var pendingPresentationSubmissionID: UInt64 = 0
    var presentationEvents = DrmPresentationEventState()
    private var ring: MailboxRing

    init(
        outputId: UInt64,
        generation: UInt64,
        drm: DrmOutput,
        slots: [ScanoutSlot],
        format: VkFormat,
        queueFamily: UInt32,
        width: Int32,
        height: Int32,
        logicalRect: OutputRect,
        fractionalScale: Double,
        cursorPlane: DrmCursorPlane?
    ) {
        self.outputId = outputId
        self.generation = generation
        self.drm = drm
        self.slots = slots
        self.format = format
        self.queueFamily = queueFamily
        self.width = width
        self.height = height
        self.logicalRect = logicalRect
        self.fractionalScale = fractionalScale
        self.cursorPlane = cursorPlane
        ring = MailboxRing(capacity: slots.count)
    }

    func nextSlot() -> ScanoutSlot {
        slots[ring.acquireSlot()]
    }

    /// Drop userspace owners only after KMS has synchronously stopped scanning
    /// this binding or the session owner has revoked the whole DRM device.
    func releaseAfterScanoutDisabled() {
        currentSlot = nil
        currentRenderSync = nil
        pendingRenderSync = nil
        cursorPlane?.destroy()
        cursorPlane = nil
        for slot in slots { slot.release() }
    }
}
