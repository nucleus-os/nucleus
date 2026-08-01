/// One DMA-BUF plane. The file descriptor is borrowed for the synchronous
/// service call; the render owner duplicates it before returning when retained.
package struct RenderDmabufPlane: Equatable, Sendable {
    package let fd: Int32
    package let offset: UInt32
    package let stride: UInt32

    package init(fd: Int32, offset: UInt32, stride: UInt32) {
        self.fd = fd
        self.offset = offset
        self.stride = stride
    }
}

package struct RenderSyncPoint: Equatable, Sendable {
    package let handle: UInt32
    package let point: UInt64

    package init(handle: UInt32, point: UInt64) {
        self.handle = handle
        self.point = point
    }
}

package struct RenderDmabufImport: Equatable, Sendable {
    package let previousIOSurfaceID: UInt32
    package let width: UInt32
    package let height: UInt32
    package let drmFormat: UInt32
    package let modifier: UInt64
    package let planes: [RenderDmabufPlane]
    package let acquire: RenderSyncPoint?
    package let release: RenderSyncPoint?

    package init(
        previousIOSurfaceID: UInt32,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [RenderDmabufPlane],
        acquire: RenderSyncPoint? = nil,
        release: RenderSyncPoint? = nil
    ) {
        self.previousIOSurfaceID = previousIOSurfaceID
        self.width = width
        self.height = height
        self.drmFormat = drmFormat
        self.modifier = modifier
        self.planes = planes
        self.acquire = acquire
        self.release = release
    }
}

package struct RenderDmabufProbe: Equatable, Sendable {
    package let width: UInt32
    package let height: UInt32
    package let drmFormat: UInt32
    package let modifier: UInt64
    package let planes: [RenderDmabufPlane]

    package init(
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [RenderDmabufPlane]
    ) {
        self.width = width
        self.height = height
        self.drmFormat = drmFormat
        self.modifier = modifier
        self.planes = planes
    }
}

package struct RenderDmabufFormat: Equatable, Sendable {
    package let format: UInt32
    package let modifier: UInt64

    package init(format: UInt32, modifier: UInt64) {
        self.format = format
        self.modifier = modifier
    }
}

package struct RenderGammaRamp: Equatable, Sendable {
    package let outputID: UInt64
    package let red: [UInt16]
    package let green: [UInt16]
    package let blue: [UInt16]

    package init(
        outputID: UInt64,
        red: [UInt16],
        green: [UInt16],
        blue: [UInt16]
    ) {
        self.outputID = outputID
        self.red = red
        self.green = green
        self.blue = blue
    }
}

package struct RenderCaptureRegion: Equatable, Sendable {
    package let x: Int32
    package let y: Int32
    package let width: Int32
    package let height: Int32

    package init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct RenderDmabufCapture: Equatable, Sendable {
    package let outputID: UInt64
    package let width: UInt32
    package let height: UInt32
    package let drmFormat: UInt32
    package let modifier: UInt64
    package let planes: [RenderDmabufPlane]
    package let sourceRegion: RenderCaptureRegion?
    package let overlaysCursor: Bool

    package init(
        outputID: UInt64,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [RenderDmabufPlane],
        sourceRegion: RenderCaptureRegion? = nil,
        overlaysCursor: Bool = false
    ) {
        self.outputID = outputID
        self.width = width
        self.height = height
        self.drmFormat = drmFormat
        self.modifier = modifier
        self.planes = planes
        self.sourceRegion = sourceRegion
        self.overlaysCursor = overlaysCursor
    }
}

package struct RenderPixelCapture: Equatable, Sendable {
    package var pixels: [UInt8]
    package let width: Int
    package let height: Int
    package let originX: Int
    package let originY: Int

    package init(
        pixels: [UInt8], width: Int, height: Int,
        originX: Int = 0, originY: Int = 0
    ) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
    }
}

/// An immutable renderer-owned surface capture. `handle` is a snapshot handle
/// suitable for retained `.snapshot` layer content, not a client IOSurface id.
package struct RenderSnapshotResource: Equatable, Sendable {
    package let handle: UInt64
    package let width: UInt32
    package let height: UInt32

    package init(handle: UInt64, width: UInt32, height: UInt32) {
        self.handle = handle
        self.width = width
        self.height = height
    }
}

/// The required render service used by the Wayland substrate. All ownership stays
/// on the compositor main actor; GPU captures complete only when the host polls
/// capture work between reactor waits.
@MainActor
package protocol CompositorRenderService: AnyObject {
    /// Copies the borrowed SHM pixels before returning. The span makes the
    /// readable extent part of the call and cannot escape into service state.
    func importShm(
        previousIOSurfaceID: UInt32,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        stride: UInt32,
        pixels: Span<UInt8>
    ) -> UInt32
    func importDmabuf(_ request: RenderDmabufImport) -> UInt32
    func releaseIOSurface(_ id: UInt32)

    func dmabufFormats() -> [RenderDmabufFormat]
    var dmabufMainDevice: UInt64 { get }
    func probeDmabuf(_ request: RenderDmabufProbe) -> Bool

    var presentationClockID: UInt32 { get }
    func gammaRampSize(outputID: UInt64) -> UInt32
    func applyGamma(_ ramp: RenderGammaRamp) -> Bool
    func clearGamma(outputID: UInt64)
    func forcePresent(outputID: UInt64)

    func importSyncobjTimeline(fd: Int32) -> UInt32?
    func destroySyncobjTimeline(handle: UInt32)

    @discardableResult
    func beginCaptureOutput(
        outputID: UInt64,
        sourceRegion: RenderCaptureRegion?,
        completion: @escaping @MainActor (RenderPixelCapture?) -> Void
    ) -> UInt64?
    @discardableResult
    func beginReadSurface(
        iosurfaceID: UInt32,
        completion: @escaping @MainActor (RenderPixelCapture?) -> Void
    ) -> UInt64?
    @discardableResult
    func beginCaptureOutput(
        to request: RenderDmabufCapture,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> UInt64?
    var hasPendingCaptureWork: Bool { get }
    var capturePollDelay: UInt64? { get }
    var captureWorkStalled: Bool { get }
    func pollCaptureWork()
    func cancelCapture(_ requestID: UInt64)

    func captureSurfaceSnapshot(iosurfaceID: UInt32) -> RenderSnapshotResource?
    func releaseSnapshot(_ handle: UInt64)
    var liveSnapshotCount: Int { get }
}
