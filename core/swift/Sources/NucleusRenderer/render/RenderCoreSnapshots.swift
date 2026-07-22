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
    // MARK: - Snapshots

    public struct CapturedSnapshot: Sendable, Equatable {
        public let handle: UInt64
        public let width: UInt32
        public let height: UInt32

        public init(handle: UInt64, width: UInt32, height: UInt32) {
            self.handle = handle
            self.width = width
            self.height = height
        }
    }

    /// Copy the current client-surface image into a renderer-owned immutable
    /// texture and register it as a retained snapshot. The copy is queued on the
    /// renderer's graphics queue under its own submission serial. Callers may
    /// retire the client's surface reference immediately: normal serial-based GPU
    /// retirement keeps the source backing alive until the copy completes.
    public func captureSurfaceSnapshot(iosurfaceID: UInt64) -> CapturedSnapshot? {
        Trace.zone("renderer.snapshot_capture", color: Trace.Color.blue) {
            snapshotTelemetry.captureAttempts &+= 1
            Trace.plot(
                "swift.nucleus.renderer.snapshot_capture_attempts",
                snapshotTelemetry.captureAttempts)
            var succeeded = false
            defer {
                if !succeeded {
                    snapshotTelemetry.capturesFailed &+= 1
                    Trace.plot(
                        "swift.nucleus.renderer.snapshot_capture_failures",
                        snapshotTelemetry.capturesFailed)
                }
            }
            // A latest SHM commit may still be coalesced in owned CPU storage
            // because no output was ready. Materialize it before resolving the
            // transition boundary.
            drainPendingShmUpload(iosurfaceID: iosurfaceID)
            guard iosurfaceID != 0,
                  let driver = frameDriver,
                  let source = driver.registry.resolve(.clientSurface(iosurfaceID)),
                  source.isValid()
            else { return nil }
            let width = source.width()
            let height = source.height()
            guard width > 0, height > 0,
                  let registeredWidth = UInt32(exactly: width),
                  let registeredHeight = UInt32(exactly: height)
            else { return nil }

            let revision = nextSnapshotContentRevision
            nextSnapshotContentRevision &+= 1
            if nextSnapshotContentRevision == 0 {
                nextSnapshotContentRevision = 1
            }
            guard let textureHandle = SnapshotCapture.captureDeviceRect(
                recorder: driver.recorder,
                source: source,
                srcX: 0,
                srcY: 0,
                width: width,
                height: height,
                into: driver.registry,
                contentRevision: revision)
            else { return nil }

            // Submit as standalone ordered GPU work. A closing client can destroy
            // its surface immediately after capture while serial retirement keeps
            // the source backing alive until this copy finishes.
            let recording = driver.recorder.snapRecording()
            let acquire = pendingClientAcquireSemaphores[iosurfaceID]
            frameSerial &+= 1
            let captureSerial = frameSerial
            guard recording.isValid(),
                  driver.submitImmediate(
                    recording,
                    waitSemaphores: acquire.map { [$0.semaphore] } ?? [],
                    submissionSerial: captureSerial)
                    == nucleus.skia.Status.ok
            else {
                _ = driver.registry.release(.renderer(textureHandle))
                return nil
            }
            lastSubmittedSerial = captureSerial
            if let acquire = pendingClientAcquireSemaphores.removeValue(
                forKey: iosurfaceID)
            {
                retiredClientAcquireSemaphores.append((
                    captureSerial,
                    acquire))
            }

            let snapshotHandle = snapshots.registerTextureHandle(
                NucleusRenderModel.TextureHandle(raw: textureHandle),
                size: Bounds(w: Float(width), h: Float(height)),
                provenance: .renderTexture).raw
            Trace.plot(
                "swift.nucleus.renderer.live_snapshots",
                UInt64(snapshots.liveCount))
            succeeded = true
            snapshotTelemetry.capturesSucceeded &+= 1
            Trace.plot(
                "swift.nucleus.renderer.snapshot_captures",
                snapshotTelemetry.capturesSucceeded)
            return CapturedSnapshot(
                handle: snapshotHandle,
                width: registeredWidth,
                height: registeredHeight)
        }
    }

    /// Current retained snapshot count for lifecycle telemetry and structural
    /// tests.
    public var liveSnapshotCount: Int { snapshots.liveCount }

    /// Register a captured/imported registry texture as a refcounted snapshot,
    /// returning the snapshot handle a layer's `.snapshot` content references.
    @discardableResult
    public func registerSnapshot(textureHandle: UInt64, width: Float, height: Float) -> UInt64 {
        let handle = snapshots.registerTextureHandle(
            NucleusRenderModel.TextureHandle(raw: textureHandle),
            size: Bounds(w: width, h: height)).raw
        Trace.plot(
            "swift.nucleus.renderer.live_snapshots",
            UInt64(snapshots.liveCount))
        return handle
    }

    /// Drop one ref on a snapshot; on the final ref, evict its backing registry
    /// texture too.
    public func releaseSnapshot(_ snapshotHandle: UInt64) {
        if let texture = snapshots.release(SnapshotHandle(raw: snapshotHandle)) {
            _ = frameDriver?.registry.release(.renderer(texture.raw))
            snapshotTelemetry.retirements &+= 1
            Trace.plot(
                "swift.nucleus.renderer.snapshot_retirements",
                snapshotTelemetry.retirements)
        }
        Trace.plot(
            "swift.nucleus.renderer.live_snapshots",
            UInt64(snapshots.liveCount))
    }
}
