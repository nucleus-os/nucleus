import NucleusSkiaGraphiteBridge
import VulkanC
import Vulkan
import Tracy
internal import NucleusRenderModel
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
@MainActor
extension RenderCore {
    /// Allocate a fresh non-zero IOSurface id for a new client surface.
    public func allocSurfaceId() -> UInt32 {
        let id = nextSurfaceId
        nextSurfaceId &+= 1
        if nextSurfaceId == 0 { nextSurfaceId = 1 }
        return id
    }

    func nextGeneration() -> UInt64 {
        let g = nextContentGeneration
        nextContentGeneration &+= 1
        return g
    }
    public func registerSurfaceTexture(
        iosurfaceID: UInt64, fd: Int32, width: UInt32, height: UInt32,
        drmFormat: UInt32, modifier: UInt64, planes: [DmaBufPlane],
        contentGeneration: UInt64, acquireFenceFd: Int32 = -1
    ) -> Bool {
        let commitInstant = telemetryClock.now
        func fail(_ stage: String) -> Bool {
            #if canImport(Glibc)
            let line = "surface-texture: failed stage=\(stage) id=\(iosurfaceID) size=\(width)x\(height) format=\(drmFormat) modifier=\(modifier) planes=\(planes.count)\n"
            line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
            #endif
            return false
        }
        guard iosurfaceID != 0 else {
            if acquireFenceFd >= 0 { close(acquireFenceFd) }
            return fail("invalid-id")
        }
        let acquireSemaphore: ClientAcquireSemaphore?
        if acquireFenceFd >= 0 {
            guard let importedSemaphore = ClientAcquireSemaphore(
                device: deviceHandle, dispatch: deviceDispatch,
                consumingSyncFd: acquireFenceFd)
            else { return fail("acquire-semaphore-import") }
            acquireSemaphore = importedSemaphore
        } else {
            acquireSemaphore = nil
        }
        guard let driver = frameDriver else { return fail("missing-frame-driver") }
        guard !planes.isEmpty else { return fail("missing-planes") }
        var importedFdBySource: [Int32: Int32] = [:]
        var importPlanes: [DmaBufPlane] = []
        importPlanes.reserveCapacity(planes.count)
        for plane in planes {
            let sourceFd = plane.fd >= 0 ? plane.fd : fd
            if importedFdBySource[sourceFd] == nil {
                let imported = dup(sourceFd)
                guard imported >= 0 else {
                    for imported in importedFdBySource.values { close(imported) }
                    return fail("dup-fd")
                }
                importedFdBySource[sourceFd] = imported
            }
            importPlanes.append(DmaBufPlane(
                fd: importedFdBySource[sourceFd] ?? -1,
                offset: plane.offset, rowPitch: plane.rowPitch))
        }
        guard let importFd = importPlanes.first?.fd, importFd >= 0 else {
            for imported in importedFdBySource.values { close(imported) }
            return fail("missing-import-fd")
        }

        let descriptor = DmaBufImageDescriptor(
            fd: importFd, width: width, height: height, drmFormat: drmFormat, modifier: modifier,
            planes: importPlanes, usage: DmaBufImageDescriptor.sampledUsage)
        guard let imported = importDmaBufImage(
            device: deviceHandle, dispatch: deviceDispatch, descriptor: descriptor
        ) else {
            return fail("vulkan-import")
        }

        let params = ScanoutImageParams(
            image: imported.handle, memory: nil, allocSize: 0,
            width: Int32(width), height: Int32(height), format: vulkanFormatForDrm(drmFormat),
            tiling: VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: DmaBufImageDescriptor.sampledUsage, queueFamilyIndex: graphicsFamily,
            hasAlpha: true)
        guard let image = driver.registry.wrapBackendImage(
            recorder: driver.recorder, descriptor: ScanoutSurface.descriptor(params)
        ) else {
            // The imported VkImage drops here (VkOwned deinit) — wrap failed.
            return fail("graphite-wrap")
        }

        // Hold the backing alive for the registry entry. A replaced backing stays
        // retired until the asynchronous presentation backend reports completion.
        if let old = importedSurfaceImages[iosurfaceID] {
            retiredSurfaceImages.append((lastSubmittedSerial, old, iosurfaceID))
        }
        importedSurfaceImages[iosurfaceID] = VkOwnedImageBox(consuming: imported)
        driver.registry.register(
            key: .clientSurface(iosurfaceID), image: image,
            width: Int32(width), height: Int32(height), contentRevision: contentGeneration)
        pendingClientAcquireSemaphores[iosurfaceID] = acquireSemaphore
        _ = pendingShmUploads.remove(iosurfaceID)
        clientUploadStats.pendingBytes = pendingShmUploads.byteCount
        if let old = clientUploadTextures.removeValue(forKey: iosurfaceID) {
            retiredClientUploadTextures.append((lastSubmittedSerial, old))
        }
        clientCommitInstants[iosurfaceID] = commitInstant
        return true
    }

    /// The content generation for a fresh client upload.
    public func freshContentGeneration() -> UInt64 { nextGeneration() }

    /// The renderer device's importable sampled dmabuf format/modifier table.
    public func dmabufSupportedFormats() -> [DmaBufFormatModifier] {
        sampleableDmaBufFormats
    }

    /// Probe the complete Vulkan external-memory path without registering client
    /// content. The caller retains its fds; duplicates are consumed by the probe.
    public func canImportSurfaceDmaBuf(
        fd: Int32,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [DmaBufPlane]
    ) -> Bool {
        guard width > 0, height > 0, !planes.isEmpty,
            sampleableDmaBufFormats.contains(
                DmaBufFormatModifier(format: drmFormat, modifier: modifier))
        else { return false }

        var importedFdBySource: [Int32: Int32] = [:]
        var importPlanes: [DmaBufPlane] = []
        importPlanes.reserveCapacity(planes.count)
        for plane in planes {
            let sourceFd = plane.fd >= 0 ? plane.fd : fd
            if importedFdBySource[sourceFd] == nil {
                let imported = dup(sourceFd)
                guard imported >= 0 else {
                    for duplicate in importedFdBySource.values { close(duplicate) }
                    return false
                }
                importedFdBySource[sourceFd] = imported
            }
            importPlanes.append(DmaBufPlane(
                fd: importedFdBySource[sourceFd] ?? -1,
                offset: plane.offset,
                rowPitch: plane.rowPitch))
        }
        guard let importFd = importPlanes.first?.fd, importFd >= 0 else {
            for duplicate in importedFdBySource.values { close(duplicate) }
            return false
        }
        let descriptor = DmaBufImageDescriptor(
            fd: importFd,
            width: width,
            height: height,
            drmFormat: drmFormat,
            modifier: modifier,
            planes: importPlanes,
            usage: DmaBufImageDescriptor.sampledUsage)
        return importDmaBufImage(
            device: deviceHandle,
            dispatch: deviceDispatch,
            descriptor: descriptor) != nil
    }

    /// Copy and coalesce a client SHM update. GPU allocation/upload is deliberately
    /// deferred to `renderReady`, outside Wayland dispatch.
    @discardableResult
    public func registerSurfaceShm(
        iosurfaceID: UInt64, pixels: Span<UInt8>,
        width: UInt32, height: UInt32, drmFormat: UInt32, stride: UInt32
    ) -> Bool {
        let commitInstant = telemetryClock.now
        guard iosurfaceID != 0, frameDriver != nil else { return false }
        guard let conversion = convertClientShmToRGBAWithMetrics(
            pixels: pixels, width: width, height: height, drmFormat: drmFormat, stride: stride)
        else { return false }
        let pending = PendingShmUpload(
            pixels: conversion.pixels,
            width: Int32(width),
            height: Int32(height),
            generation: nextGeneration())
        if pendingShmUploads.enqueue(pending, for: iosurfaceID) {
            clientUploadStats.coalesced &+= 1
        }
        clientUploadStats.enqueued &+= 1
        clientUploadStats.fullSizeOwnedAllocations &+=
            conversion.metrics.fullSizeOwnedAllocations
        clientUploadStats.ownedAllocationBytes &+=
            conversion.metrics.ownedAllocationBytes
        clientUploadStats.bytesCopied &+=
            conversion.metrics.bytesCopied
        clientUploadStats.pendingBytes = pendingShmUploads.byteCount
        clientCommitInstants[iosurfaceID] = commitInstant
        return true
    }

    func drainPendingShmUploads() {
        guard !pendingShmUploads.isEmpty, let driver = frameDriver else { return }
        let uploads = pendingShmUploads.drain()
        clientUploadStats.pendingBytes = 0
        for (iosurfaceID, pending) in uploads {
            materializeShmUpload(
                pending,
                iosurfaceID: iosurfaceID,
                driver: driver)
        }
    }

    /// Materialize only one queued SHM generation for a transition capture. A
    /// close/tile on one surface must not turn Wayland dispatch into a bulk upload
    /// of unrelated clients.
    func drainPendingShmUpload(iosurfaceID: UInt64) {
        guard let driver = frameDriver,
              let pending = pendingShmUploads.remove(iosurfaceID)
        else { return }
        clientUploadStats.pendingBytes = pendingShmUploads.byteCount
        materializeShmUpload(
            pending,
            iosurfaceID: iosurfaceID,
            driver: driver)
    }

    func materializeShmUpload(
        _ pending: PendingShmUpload,
        iosurfaceID: UInt64,
        driver: FrameDriver
    ) {
        guard let texture = driver.stageClientUpload(
            replacing: clientUploadTextures[iosurfaceID],
            pixels: pending.pixels,
            width: pending.width,
            height: pending.height)
        else {
            clientUploadStats.failed &+= 1
            return
        }
        let image = texture.image()
        guard image.isValid() else {
            clientUploadStats.failed &+= 1
            return
        }
        // Switching from DMA-BUF to SHM retires the borrowed image after the
        // presentation backend reports that asynchronous GPU use is complete.
        if let old = importedSurfaceImages[iosurfaceID] {
            retiredSurfaceImages.append((
                lastSubmittedSerial,
                old,
                iosurfaceID))
        }
        importedSurfaceImages[iosurfaceID] = nil
        if let old = clientUploadTextures.updateValue(
            texture,
            forKey: iosurfaceID)
        {
            retiredClientUploadTextures.append((
                lastSubmittedSerial,
                old))
        }
        driver.registry.register(
            key: .clientSurface(iosurfaceID),
            image: image,
            width: pending.width,
            height: pending.height,
            contentRevision: pending.generation)
        clientUploadStats.uploaded &+= 1
    }
    /// Drop a client surface's imported texture (surface destroyed / content
    /// detached). Evicts the registry entry + releases the backing VkImage.
    public func releaseSurfaceTexture(iosurfaceID: UInt64) {
        clientCommitInstants[iosurfaceID] = nil
        pendingClientAcquireSemaphores[iosurfaceID] = nil
        _ = frameDriver?.registry.release(.clientSurface(iosurfaceID))
        _ = pendingShmUploads.remove(iosurfaceID)
        clientUploadStats.pendingBytes = pendingShmUploads.byteCount
        if let old = clientUploadTextures.removeValue(forKey: iosurfaceID) {
            retiredClientUploadTextures.append((lastSubmittedSerial, old))
        }
        if let old = importedSurfaceImages[iosurfaceID] {
            retiredSurfaceImages.append((lastSubmittedSerial, old, iosurfaceID))
        }
        importedSurfaceImages[iosurfaceID] = nil
    }

    /// Drop an acquire semaphore that the DRM direct-scanout path consumed through
    /// its duplicate sync_file. It was never submitted to Vulkan and is safe to
    /// destroy immediately after the atomic commit accepts the buffer.
    public func discardPendingSurfaceAcquire(iosurfaceID: UInt64) {
        pendingClientAcquireSemaphores[iosurfaceID] = nil
    }
}
