import NucleusSkiaGraphiteBridge
import VulkanC
import Vulkan
import Tracy
import NucleusRenderModel
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
@MainActor
extension RenderCore {
    // MARK: - Screencopy / screenshot readback

    /// Start a nonblocking read of an output's composited accumulator. Completion
    /// is delivered from `pollCaptureWork`, never from the initiating call.
    @_spi(NucleusPlatform)
    @discardableResult
    public func beginCaptureOutputBGRA(
        outputID: UInt64,
        sourceX: Int32 = 0,
        sourceY: Int32 = 0,
        sourceWidth: Int32 = 0,
        sourceHeight: Int32 = 0,
        completion: @escaping @MainActor (PixelCapture?) -> Void
    ) -> UInt64? {
        guard !captureWorkStalled else { return nil }
        guard let driver = frameDriver,
              let accumulator = driver.accumulator(for: outputID)
        else { return nil }
        let surface = accumulator.surface
        let surfaceWidth = surface.width()
        let surfaceHeight = surface.height()
        let usesRegion = sourceWidth > 0 || sourceHeight > 0
        let x = usesRegion ? sourceX : 0
        let y = usesRegion ? sourceY : 0
        let width = usesRegion ? sourceWidth : surfaceWidth
        let height = usesRegion ? sourceHeight : surfaceHeight
        guard x >= 0, y >= 0, width > 0, height > 0,
              x <= surfaceWidth - width,
              y <= surfaceHeight - height,
              let byteCount = Self.captureByteCount(
                width: Int(width), height: Int(height))
        else {
            rejectCapture()
            return nil
        }
        let key = PixelCaptureKey(
            outputID: outputID,
            submissionSerial: lastSubmittedSerial,
            x: x, y: y, width: width, height: height)
        let requestID = allocateCaptureRequestID()
        if let jobID = pixelCaptureJobByKey[key],
           let job = pendingPixelCaptureJobs[jobID]
        {
            job.subscribers.append(PixelCaptureSubscriber(
                requestID: requestID,
                completion: completion))
            pixelCaptureJobByRequest[requestID] = jobID
            coalescedPixelCaptureCount &+= 1
            capturePollDelayNanoseconds =
                Self.capturePollMinimumNanoseconds
            publishCaptureQueueTelemetry()
            return requestID
        }
        guard pendingPixelCaptureJobs.count
                < Self.maximumPendingPixelCaptureJobs,
              pendingPixelCaptureBytes
                <= Self.maximumPendingPixelCaptureBytes - byteCount
        else {
            rejectCapture()
            return nil
        }
        let startedAt = telemetryClock.now
        let readback = usesRegion
            ? context.beginSurfaceReadbackBGRARegion(
                surface, x, y, width, height)
            : context.beginSurfaceReadbackBGRA(surface)
        guard readback.isValid() else { return nil }
        pendingPixelCaptureJobs[requestID] = PendingPixelCaptureJob(
            key: key,
            readback: readback,
            retainedSurface: surface,
            originX: Int(x),
            originY: Int(y),
            width: Int(width),
            height: Int(height),
            byteCount: byteCount,
            startedAt: startedAt,
            subscriber: PixelCaptureSubscriber(
                requestID: requestID,
                completion: completion))
        pixelCaptureJobByKey[key] = requestID
        pixelCaptureJobByRequest[requestID] = requestID
        pendingPixelCaptureBytes += byteCount
        capturePollDelayNanoseconds = Self.capturePollMinimumNanoseconds
        publishCaptureQueueTelemetry()
        return requestID
    }

    /// Start a nonblocking read of a registered client texture. The temporary
    /// offscreen surface stays alive through callback completion.
    @_spi(NucleusPlatform)
    @discardableResult
    public func beginReadSurfaceTextureBGRA(
        iosurfaceID: UInt64,
        completion: @escaping @MainActor (PixelCapture?) -> Void
    ) -> UInt64? {
        guard !captureWorkStalled,
              pendingPixelCaptureJobs.count
                < Self.maximumPendingPixelCaptureJobs
        else {
            rejectCapture()
            return nil
        }
        guard let driver = frameDriver,
              let image = driver.registry.resolve(iosurfaceID), image.isValid()
        else { return nil }
        let width = image.width()
        let height = image.height()
        guard width > 0, height > 0,
              let byteCount = Self.captureByteCount(
                width: Int(width), height: Int(height)),
              pendingPixelCaptureBytes
                <= Self.maximumPendingPixelCaptureBytes - byteCount
        else {
            rejectCapture()
            return nil
        }
        let startedAt = telemetryClock.now
        let surface = driver.recorder.makeOffscreenSurface(width, height)
        guard surface.isValid() else { return nil }
        var source = nucleus.skia.RectF()
        source.width = Float(width); source.height = Float(height)
        var paint = nucleus.skia.Paint()
        paint.blend = nucleus.skia.BlendMode.src
        surface.getCanvas().drawImageRect(image, source, source, paint)
        let recording = driver.recorder.snapRecording()
        guard recording.isValid() else { return nil }
        let serial = allocateSubmissionSerial()
        guard context.submitAsync(recording, serial)
                == nucleus.skia.Status.ok
        else { return nil }
        lastSubmittedSerial = serial
        let readback = context.beginSurfaceReadbackBGRA(surface)
        guard readback.isValid() else { return nil }
        let requestID = allocateCaptureRequestID()
        pendingPixelCaptureJobs[requestID] = PendingPixelCaptureJob(
            key: nil,
            readback: readback,
            retainedSurface: surface,
            originX: 0,
            originY: 0,
            width: Int(width),
            height: Int(height),
            byteCount: byteCount,
            startedAt: startedAt,
            subscriber: PixelCaptureSubscriber(
                requestID: requestID,
                completion: completion))
        pixelCaptureJobByRequest[requestID] = requestID
        pendingPixelCaptureBytes += byteCount
        capturePollDelayNanoseconds = Self.capturePollMinimumNanoseconds
        publishCaptureQueueTelemetry()
        return requestID
    }

    /// Queue a compositor-accumulator blit into a client dmabuf without waiting on
    /// the CPU. The imported image and Graphite surface are retained until the GPU
    /// completion serial advances past this capture.
    @_spi(NucleusPlatform)
    @discardableResult
    public func beginCaptureOutputToDmabuf(
        outputID: UInt64,
        fd: Int32, width: UInt32, height: UInt32, drmFormat: UInt32, modifier: UInt64,
        planes: [DmaBufPlane], sourceX: Int32 = 0, sourceY: Int32 = 0,
        sourceWidth: Int32 = 0, sourceHeight: Int32 = 0,
        overlay: CaptureOverlay? = nil,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> UInt64? {
        guard !captureWorkStalled,
              pendingDmabufCaptures.count
                < Self.maximumPendingDmabufCaptureJobs,
              let checkedWidth = Int32(exactly: width),
              let checkedHeight = Int32(exactly: height),
              checkedWidth > 0, checkedHeight > 0
        else {
            rejectCapture()
            return nil
        }
        guard let driver = frameDriver,
              let accumulator = driver.accumulator(for: outputID)
        else { return nil }
        let startedAt = telemetryClock.now
        let descriptor = DmaBufImageDescriptor(
            fd: fd, width: width, height: height, drmFormat: drmFormat, modifier: modifier,
            planes: planes, usage: DmaBufImageDescriptor.scanoutUsage)
        guard let imported = importDmaBufImage(
            device: deviceHandle, dispatch: deviceDispatch, descriptor: descriptor
        ) else { return nil }
        guard let submitted = submitAccumulatorBlit(
            accumulator, image: imported.handle, recorder: driver.recorder,
            width: checkedWidth, height: checkedHeight,
            format: vulkanFormatForDrm(drmFormat),
            sourceX: sourceX, sourceY: sourceY,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, overlay: overlay)
        else {
            _ = consume imported
            return nil
        }
        let requestID = allocateCaptureRequestID()
        pendingDmabufCaptures[requestID] = PendingDmabufCapture(
            submissionSerial: submitted.serial,
            surface: submitted.surface,
            image: VkOwnedImageBox(consuming: imported),
            startedAt: startedAt,
            completion: completion)
        capturePollDelayNanoseconds = Self.capturePollMinimumNanoseconds
        publishCaptureQueueTelemetry()
        return requestID
    }

    func submitAccumulatorBlit(
        _ accumulator: OutputAccumulator, image: VkImage, recorder: nucleus.skia.Recorder,
        width: Int32, height: Int32, format: VkFormat,
        sourceX: Int32, sourceY: Int32, sourceWidth: Int32, sourceHeight: Int32,
        overlay: CaptureOverlay?
    ) -> (surface: nucleus.skia.Surface, serial: UInt64)? {
        let params = ScanoutImageParams(
            image: image, memory: nil, allocSize: 0,
            width: width, height: height, format: format,
            tiling: VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: DmaBufImageDescriptor.scanoutUsage, queueFamilyIndex: graphicsFamily,
            hasAlpha: false)
        let surface = ScanoutSurface.wrap(recorder: recorder, params: params)
        var source: nucleus.skia.RectF?
        if sourceWidth > 0, sourceHeight > 0 {
            var rect = nucleus.skia.RectF()
            rect.x = Float(sourceX); rect.y = Float(sourceY)
            rect.width = Float(sourceWidth); rect.height = Float(sourceHeight)
            source = rect
        }
        guard surface.isValid(), accumulator.present(onto: surface, source: source)
        else { return nil }
        if let overlay,
           overlay.width > 0, overlay.height > 0,
           overlay.rgbaPixels.count >= Int(overlay.width) * Int(overlay.height) * 4 {
            let image = overlay.rgbaPixels.withUnsafeBufferPointer {
                nucleus.skia.makeRasterImageRGBA(
                    overlay.width, overlay.height, $0.baseAddress, $0.count)
            }
            if image.isValid() {
                var src = nucleus.skia.RectF()
                src.width = Float(overlay.width); src.height = Float(overlay.height)
                var dst = src
                dst.x = Float(overlay.x - sourceX)
                dst.y = Float(overlay.y - sourceY)
                var paint = nucleus.skia.Paint()
                paint.blend = nucleus.skia.BlendMode.srcOver
                surface.getCanvas().drawImageRect(image, src, dst, paint)
            }
        }
        let recording = recorder.snapRecording()
        guard recording.isValid() else { return nil }
        let serial = allocateSubmissionSerial()
        guard context.submitAsync(recording, serial)
                == nucleus.skia.Status.ok
        else { return nil }
        lastSubmittedSerial = serial
        return (surface, serial)
    }

    @_spi(NucleusPlatform)
    public var hasPendingCaptureWork: Bool {
        !pendingPixelCaptureJobs.isEmpty
            || !pendingDmabufCaptures.isEmpty
    }

    /// The host folds this relative delay into its single reactor timer. Fast
    /// polling is used only immediately after submission or progress; an idle GPU
    /// completion queue backs off to the presentation-scale ceiling.
    @_spi(NucleusPlatform)
    public var capturePollDelay: UInt64? {
        hasPendingCaptureWork ? capturePollDelayNanoseconds : nil
    }

    @_spi(NucleusPlatform)
    public func pollCaptureWork() {
        guard hasPendingCaptureWork else { return }
        let completedSerial = context.pollCompletedSubmissionSerial()
        var madeProgress = false

        let completedPixelIDs = pendingPixelCaptureJobs.compactMap {
            $0.value.readback.isComplete() ? $0.key : nil
        }
        for jobID in completedPixelIDs {
            guard let pending = pendingPixelCaptureJobs.removeValue(
                forKey: jobID)
            else { continue }
            madeProgress = true
            pendingPixelCaptureBytes -= pending.byteCount
            if let key = pending.key,
               pixelCaptureJobByKey[key] == jobID
            {
                pixelCaptureJobByKey[key] = nil
            }
            let completions = pending.subscribers.compactMap { subscriber in
                pixelCaptureJobByRequest[subscriber.requestID] = nil
                return subscriber.completion
            }
            Trace.plot(
                "swift.nucleus.renderer.capture.pixel_gpu_ready_ms",
                Double(elapsedNanoseconds(
                    pending.startedAt, telemetryClock.now)) / 1_000_000.0)
            var pixels = [UInt8](
                repeating: 0,
                count: pending.byteCount)
            let copyStartedAt = telemetryClock.now
            let status = pixels.withUnsafeMutableBufferPointer {
                pending.readback.copyPixels(
                    $0.baseAddress,
                    $0.count,
                    Int32(pending.width * 4))
            }
            Trace.plot(
                "swift.nucleus.renderer.capture.pixel_copy_ms",
                Double(elapsedNanoseconds(
                    copyStartedAt, telemetryClock.now)) / 1_000_000.0)
            pending.retainedSurface = nil
            let capture: PixelCapture? = status == nucleus.skia.Status.ok
                ? PixelCapture(
                    pixels: pixels,
                    width: pending.width,
                    height: pending.height,
                    originX: pending.originX,
                    originY: pending.originY)
                : nil
            if completions.isEmpty {
                Trace.plot(
                    "swift.nucleus.renderer.capture.cancelled_pixel_retire_ms",
                    Double(elapsedNanoseconds(
                        pending.startedAt, telemetryClock.now)) / 1_000_000.0)
            }
            for completion in completions {
                completion(capture)
            }
        }

        let completedDmabufIDs = pendingDmabufCaptures.compactMap {
            $0.value.submissionSerial <= completedSerial ? $0.key : nil
        }
        for requestID in completedDmabufIDs {
            guard let pending = pendingDmabufCaptures.removeValue(
                forKey: requestID)
            else { continue }
            madeProgress = true
            Trace.plot(
                "swift.nucleus.renderer.capture.dmabuf_gpu_ready_ms",
                Double(elapsedNanoseconds(
                    pending.startedAt, telemetryClock.now)) / 1_000_000.0)
            pending.releaseBacking()
            if pending.completion == nil {
                Trace.plot(
                    "swift.nucleus.renderer.capture.cancelled_dmabuf_retire_ms",
                    Double(elapsedNanoseconds(
                        pending.startedAt, telemetryClock.now)) / 1_000_000.0)
            }
            pending.completion?(true)
            pending.completion = nil
        }

        detectCaptureStall()
        if madeProgress {
            capturePollDelayNanoseconds = Self.capturePollMinimumNanoseconds
        } else {
            let doubled = capturePollDelayNanoseconds
                .multipliedReportingOverflow(by: 2)
            capturePollDelayNanoseconds = min(
                doubled.overflow ? UInt64.max : doubled.partialValue,
                Self.capturePollMaximumNanoseconds)
        }
        publishCaptureQueueTelemetry()
    }

    @_spi(NucleusPlatform)
    public func cancelCapture(_ requestID: UInt64) {
        if let jobID = pixelCaptureJobByRequest.removeValue(
            forKey: requestID),
           let pending = pendingPixelCaptureJobs[jobID],
           let index = pending.subscribers.firstIndex(where: {
               $0.requestID == requestID
           })
        {
            pending.subscribers[index].completion = nil
            publishCaptureQueueTelemetry()
            return
        }
        if let pending = pendingDmabufCaptures[requestID] {
            pending.completion = nil
            publishCaptureQueueTelemetry()
        }
    }

    static func captureByteCount(
        width: Int, height: Int
    ) -> Int? {
        guard width > 0, height > 0,
              width <= Int(Int32.max) / 4
        else { return nil }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { return nil }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard !bytes.overflow, bytes.partialValue > 0 else { return nil }
        return bytes.partialValue
    }

    func rejectCapture() {
        rejectedCaptureCount &+= 1
        Trace.plot(
            "swift.nucleus.renderer.capture.rejected",
            rejectedCaptureCount)
    }

    func detectCaptureStall() {
        guard !captureWorkStalled else { return }
        let now = telemetryClock.now
        let oldestPixel = pendingPixelCaptureJobs.values.map {
            elapsedNanoseconds($0.startedAt, now)
        }.max() ?? 0
        let oldestDmabuf = pendingDmabufCaptures.values.map {
            elapsedNanoseconds($0.startedAt, now)
        }.max() ?? 0
        guard max(oldestPixel, oldestDmabuf)
                >= Self.captureStallNanoseconds
        else { return }

        captureWorkStalled = true
        var pixelFailures: [@MainActor (PixelCapture?) -> Void] = []
        for pending in pendingPixelCaptureJobs.values {
            for index in pending.subscribers.indices {
                pixelCaptureJobByRequest[
                    pending.subscribers[index].requestID] = nil
                if let completion = pending.subscribers[index].completion {
                    pixelFailures.append(completion)
                    pending.subscribers[index].completion = nil
                }
            }
        }
        var dmabufFailures: [@MainActor (Bool) -> Void] = []
        for pending in pendingDmabufCaptures.values {
            if let completion = pending.completion {
                dmabufFailures.append(completion)
                pending.completion = nil
            }
        }
        Trace.plot("swift.nucleus.renderer.capture.stalled", UInt64(1))
        for completion in pixelFailures { completion(nil) }
        for completion in dmabufFailures { completion(false) }
    }

    func publishCaptureQueueTelemetry() {
        Trace.plot(
            "swift.nucleus.renderer.capture.pending_pixel_jobs",
            UInt64(pendingPixelCaptureJobs.count))
        Trace.plot(
            "swift.nucleus.renderer.capture.pending_pixel_bytes",
            UInt64(pendingPixelCaptureBytes))
        Trace.plot(
            "swift.nucleus.renderer.capture.coalesced_pixel_requests",
            coalescedPixelCaptureCount)
        Trace.plot(
            "swift.nucleus.renderer.capture.pending_dmabufs",
            UInt64(pendingDmabufCaptures.count))
        Trace.plot(
            "swift.nucleus.renderer.capture.cancelled_pixel_jobs",
            UInt64(pendingPixelCaptureJobs.values.filter {
                $0.subscribers.allSatisfy { $0.completion == nil }
            }.count))
        Trace.plot(
            "swift.nucleus.renderer.capture.cancelled_dmabufs",
            UInt64(pendingDmabufCaptures.values.filter {
                $0.completion == nil
            }.count))
    }

    func allocateCaptureRequestID() -> UInt64 {
        let requestID = nextCaptureRequestID
        nextCaptureRequestID &+= 1
        precondition(nextCaptureRequestID != 0, "capture request space exhausted")
        return requestID
    }

    func allocateSubmissionSerial() -> UInt64 {
        frameSerial &+= 1
        precondition(frameSerial != 0, "submission serial space exhausted")
        return frameSerial
    }

}
