import NucleusCompositorDrmC
@_spi(NucleusPlatform) import NucleusRenderer
import Glibc

@MainActor
extension RendererRuntime {
    @discardableResult
    public func registerSurfaceDmabuf(
        iosurfaceID: UInt64,
        fd: Int32,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [DmaBufPlane],
        acquire: DmaBufSyncPoint? = nil,
        release: DmaBufSyncPoint? = nil
    ) -> Bool {
        let acquireFenceFD: Int32
        if let acquire {
            guard let exported = exportSyncPoint(acquire)
            else { return false }
            acquireFenceFD = exported
        } else {
            acquireFenceFD = -1
        }
        let diagnostic = DiagnosticSyncFile(
            duplicating: acquireFenceFD)
        let scanoutAcquireFenceFD = acquireFenceFD >= 0
            ? dup(acquireFenceFD)
            : -1
        let previousRelease =
            pendingSurfaceReleaseSync[iosurfaceID]
        let imported = core.registerSurfaceTexture(
            iosurfaceID: iosurfaceID,
            fd: fd,
            width: width,
            height: height,
            drmFormat: drmFormat,
            modifier: modifier,
            planes: planes,
            contentGeneration:
                core.freshContentGeneration(),
            acquireFenceFd: acquireFenceFD)
        guard imported else {
            if scanoutAcquireFenceFD >= 0 {
                close(scanoutAcquireFenceFD)
            }
            if let release {
                signalSyncPoint(release)
            }
            return false
        }
        pendingClientAcquireFenceDiagnostics[
            iosurfaceID] = diagnostic

        if let previousRelease {
            pendingSurfaceReleaseSync[iosurfaceID] = nil
            if isSurfaceScannedOut(iosurfaceID),
                let prior =
                    clientScanoutBuffers[iosurfaceID]
            {
                suppressedCompositeRetireNotifications[
                    iosurfaceID, default: 0] += 1
                prior.onDestroy = { [weak self] in
                    self?.signalSyncPoint(previousRelease)
                    self?.onSurfaceBufferRetired?(
                        iosurfaceID)
                }
            } else {
                retiredCompositeReleaseSync[
                    iosurfaceID, default: []
                ].append(previousRelease)
            }
        }
        if let release {
            pendingSurfaceReleaseSync[iosurfaceID] =
                release
        }

        releaseClientScanout(iosurfaceID)
        if isOpaqueScanoutFormat(drmFormat) {
            clientScanoutBuffers[iosurfaceID] =
                ClientScanoutBuffer.retain(
                    device: drmDevice,
                    gemTable: gemHandleTable,
                    fd: fd,
                    width: width,
                    height: height,
                    format: drmFormat,
                    modifier: modifier,
                    planes: planes,
                    acquireFenceFd:
                        scanoutAcquireFenceFD)
            if clientScanoutBuffers[iosurfaceID] == nil,
                scanoutAcquireFenceFD >= 0
            {
                close(scanoutAcquireFenceFD)
            }
        } else if scanoutAcquireFenceFD >= 0 {
            close(scanoutAcquireFenceFD)
        }
        return true
    }

    private func releaseClientScanout(
        _ iosurfaceID: UInt64
    ) {
        clientScanoutBuffers.removeValue(
            forKey: iosurfaceID)
    }

    private func isSurfaceScannedOut(
        _ iosurfaceID: UInt64
    ) -> Bool {
        scanoutSurfaces.isScannedOut(iosurfaceID)
    }

    func clientScanoutFramebuffer(
        iosurfaceID: UInt64,
        validateWith drm: DrmOutput
    ) -> UInt32 {
        guard let buffer =
            clientScanoutBuffers[iosurfaceID]
        else { return 0 }
        let framebufferID = buffer.framebufferId()
        guard framebufferID != 0,
            drm.testScanoutCommit(fbId: framebufferID)
        else { return 0 }
        return framebufferID
    }

    @discardableResult
    public func registerSurfaceShm(
        iosurfaceID: UInt64,
        pixels: UnsafeRawBufferPointer,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        stride: UInt32
    ) -> Bool {
        let registered = core.registerSurfaceShm(
            iosurfaceID: iosurfaceID,
            pixels: pixels,
            width: width,
            height: height,
            drmFormat: drmFormat,
            stride: stride)
        if registered {
            pendingClientAcquireFenceDiagnostics[
                iosurfaceID] = nil
        }
        return registered
    }

    public func releaseSurfaceTexture(
        iosurfaceID: UInt64
    ) {
        pendingClientAcquireFenceDiagnostics[
            iosurfaceID] = nil
        if isSurfaceScannedOut(iosurfaceID),
            let buffer =
                clientScanoutBuffers[iosurfaceID],
            let deferred =
                pendingSurfaceReleaseSync.removeValue(
                    forKey: iosurfaceID)
        {
            suppressedCompositeRetireNotifications[
                iosurfaceID, default: 0] += 1
            buffer.onDestroy = { [weak self] in
                self?.signalSyncPoint(deferred)
                self?.onSurfaceBufferRetired?(
                    iosurfaceID)
            }
        } else if let deferred =
            pendingSurfaceReleaseSync.removeValue(
                forKey: iosurfaceID)
        {
            retiredCompositeReleaseSync[
                iosurfaceID, default: []
            ].append(deferred)
        }
        releaseClientScanout(iosurfaceID)
        core.releaseSurfaceTexture(
            iosurfaceID: iosurfaceID)
    }

    public func dmabufSupportedFormats()
        -> [DmaBufFormatModifier]
    {
        core.dmabufSupportedFormats()
    }

    public func canImportSurfaceDmabuf(
        fd: Int32,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [DmaBufPlane]
    ) -> Bool {
        core.canImportSurfaceDmaBuf(
            fd: fd,
            width: width,
            height: height,
            drmFormat: drmFormat,
            modifier: modifier,
            planes: planes)
    }

    @_spi(NucleusPlatform)
    @discardableResult
    public func beginCaptureOutputBGRA(
        outputID: UInt64,
        sourceX: Int32 = 0,
        sourceY: Int32 = 0,
        sourceWidth: Int32 = 0,
        sourceHeight: Int32 = 0,
        completion: @escaping @MainActor (RenderCore.PixelCapture?) -> Void
    ) -> UInt64? {
        core.beginCaptureOutputBGRA(
            outputID: outputID,
            sourceX: sourceX,
            sourceY: sourceY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            completion: completion)
    }

    @_spi(NucleusPlatform)
    @discardableResult
    public func beginReadSurfaceTextureBGRA(
        iosurfaceID: UInt32,
        completion: @escaping @MainActor (RenderCore.PixelCapture?) -> Void
    ) -> UInt64? {
        core.beginReadSurfaceTextureBGRA(
            iosurfaceID: UInt64(iosurfaceID),
            completion: completion)
    }

    @discardableResult
    public func beginCaptureOutputToDmabuf(
        outputID: UInt64,
        fd: Int32,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [DmaBufPlane],
        sourceX: Int32 = 0,
        sourceY: Int32 = 0,
        sourceWidth: Int32 = 0,
        sourceHeight: Int32 = 0,
        overlayCursor: Bool = false,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> UInt64? {
        let overlay = overlayCursor
            ? captureCursorOverlay(outputID: outputID)
            : nil
        return core.beginCaptureOutputToDmabuf(
            outputID: outputID,
            fd: fd,
            width: width,
            height: height,
            drmFormat: drmFormat,
            modifier: modifier,
            planes: planes,
            sourceX: sourceX,
            sourceY: sourceY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            overlay: overlay,
            completion: completion)
    }

    public var hasPendingCaptureWork: Bool {
        core.hasPendingCaptureWork
    }

    public var capturePollDelay: UInt64? {
        core.capturePollDelay
    }

    public var captureWorkStalled: Bool {
        core.captureWorkStalled
    }

    public func pollCaptureWork() {
        core.pollCaptureWork()
    }

    public func cancelCapture(_ requestID: UInt64) {
        core.cancelCapture(requestID)
    }

    private func captureCursorOverlay(
        outputID: UInt64
    ) -> CaptureOverlay? {
        guard let binding = bindings[outputID],
            cursorImageWidth > 0,
            cursorImageHeight > 0,
            cursorPixels.count
                >= Int(cursorImageWidth
                    * cursorImageHeight * 4)
        else { return nil }
        var rgba = cursorPixels
        for index in stride(
            from: 0, to: rgba.count, by: 4)
        {
            rgba.swapAt(index, index + 2)
        }
        let x = Int32(
            ((cursorX - binding.logicalRect.x)
                * binding.fractionalScale).rounded())
            - cursorHotspotX
        let y = Int32(
            ((cursorY - binding.logicalRect.y)
                * binding.fractionalScale).rounded())
            - cursorHotspotY
        return CaptureOverlay(
            rgbaPixels: rgba,
            width: Int32(cursorImageWidth),
            height: Int32(cursorImageHeight),
            x: x,
            y: y)
    }

    @discardableResult
    public func registerSnapshot(
        textureHandle: UInt64,
        width: Float,
        height: Float
    ) -> UInt64 {
        core.registerSnapshot(
            textureHandle: textureHandle,
            width: width,
            height: height)
    }

    public func captureSurfaceSnapshot(
        iosurfaceID: UInt64
    ) -> RenderCore.CapturedSnapshot? {
        core.captureSurfaceSnapshot(iosurfaceID: iosurfaceID)
    }

    public var liveSnapshotCount: Int {
        core.liveSnapshotCount
    }

    public func releaseSnapshot(
        _ snapshotHandle: UInt64
    ) {
        core.releaseSnapshot(snapshotHandle)
    }

    public func importSyncobjTimeline(
        fd: Int32
    ) -> UInt32? {
        guard let drmDeviceFd = drmDevice.availableFileDescriptor,
              fd >= 0
        else {
            return nil
        }
        var handle: UInt32 = 0
        guard drmSyncobjFDToHandle(
            drmDeviceFd, fd, &handle) == 0,
            handle != 0
        else { return nil }
        return handle
    }

    public func destroySyncobjTimeline(
        handle: UInt32
    ) {
        if let drmDeviceFd = drmDevice.availableFileDescriptor,
           handle != 0
        {
            _ = drmSyncobjDestroy(
                drmDeviceFd, handle)
        }
    }

    private func exportSyncPoint(
        _ sync: DmaBufSyncPoint
    ) -> Int32? {
        guard let drmDeviceFd = drmDevice.availableFileDescriptor,
              sync.handle != 0
        else { return nil }
        var temporary: UInt32 = 0
        guard drmSyncobjCreate(
            drmDeviceFd, 0, &temporary) == 0,
            temporary != 0
        else { return nil }
        defer {
            _ = drmSyncobjDestroy(
                drmDeviceFd, temporary)
        }
        guard drmSyncobjTransfer(
            drmDeviceFd,
            temporary,
            0,
            sync.handle,
            sync.point,
            0) == 0
        else { return nil }
        var fd: Int32 = -1
        guard drmSyncobjExportSyncFile(
            drmDeviceFd, temporary, &fd) == 0,
            fd >= 0
        else { return nil }
        return fd
    }

    func signalSyncPoint(_ sync: DmaBufSyncPoint) {
        guard let drmDeviceFd = drmDevice.availableFileDescriptor,
              sync.handle != 0
        else { return }
        var handle = sync.handle
        var point = sync.point
        _ = drmSyncobjTimelineSignal(
            drmDeviceFd, &handle, &point, 1)
    }

    private func signalRetiredCompositeRelease(
        iosurfaceID: UInt64
    ) {
        guard var releases =
            retiredCompositeReleaseSync[iosurfaceID],
            !releases.isEmpty
        else { return }
        let release = releases.removeFirst()
        if releases.isEmpty {
            retiredCompositeReleaseSync[iosurfaceID] = nil
        } else {
            retiredCompositeReleaseSync[iosurfaceID] =
                releases
        }
        signalSyncPoint(release)
    }

    func retiredCompositeBacking(
        iosurfaceID: UInt64
    ) {
        signalRetiredCompositeRelease(
            iosurfaceID: iosurfaceID)
        if let suppressed =
            suppressedCompositeRetireNotifications[
                iosurfaceID],
            suppressed > 0
        {
            if suppressed == 1 {
                suppressedCompositeRetireNotifications[
                    iosurfaceID] = nil
            } else {
                suppressedCompositeRetireNotifications[
                    iosurfaceID] = suppressed - 1
            }
            return
        }
        onSurfaceBufferRetired?(iosurfaceID)
    }

    func signalPendingSurfaceReleases() {
        let pending = pendingSurfaceReleaseSync.values
        pendingSurfaceReleaseSync.removeAll(
            keepingCapacity: true)
        for release in pending {
            signalSyncPoint(release)
        }
        let retired =
            retiredCompositeReleaseSync.values.flatMap {
                $0
            }
        retiredCompositeReleaseSync.removeAll(
            keepingCapacity: true)
        for release in retired {
            signalSyncPoint(release)
        }
    }
}
