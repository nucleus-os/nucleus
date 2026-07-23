/// One DMA-BUF plane. The file descriptor is borrowed for the synchronous
/// service call; the render owner duplicates it before returning when retained.
public struct RenderDmabufPlane: Equatable, Sendable {
    public let fd: Int32
    public let offset: UInt32
    public let stride: UInt32

    public init(fd: Int32, offset: UInt32, stride: UInt32) {
        self.fd = fd
        self.offset = offset
        self.stride = stride
    }
}

public struct RenderSyncPoint: Equatable, Sendable {
    public let handle: UInt32
    public let point: UInt64

    public init(handle: UInt32, point: UInt64) {
        self.handle = handle
        self.point = point
    }
}

public struct RenderDmabufImport: Equatable, Sendable {
    public let previousIOSurfaceID: UInt32
    public let width: UInt32
    public let height: UInt32
    public let drmFormat: UInt32
    public let modifier: UInt64
    public let planes: [RenderDmabufPlane]
    public let acquire: RenderSyncPoint?
    public let release: RenderSyncPoint?

    public init(
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

public struct RenderDmabufProbe: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let drmFormat: UInt32
    public let modifier: UInt64
    public let planes: [RenderDmabufPlane]

    public init(
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

public struct RenderDmabufFormat: Equatable, Sendable {
    public let format: UInt32
    public let modifier: UInt64

    public init(format: UInt32, modifier: UInt64) {
        self.format = format
        self.modifier = modifier
    }
}

public struct RenderGammaRamp: Equatable, Sendable {
    public let outputID: UInt64
    public let red: [UInt16]
    public let green: [UInt16]
    public let blue: [UInt16]

    public init(
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

public struct RenderCaptureRegion: Equatable, Sendable {
    public let x: Int32
    public let y: Int32
    public let width: Int32
    public let height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RenderDmabufCapture: Equatable, Sendable {
    public let outputID: UInt64
    public let width: UInt32
    public let height: UInt32
    public let drmFormat: UInt32
    public let modifier: UInt64
    public let planes: [RenderDmabufPlane]
    public let sourceRegion: RenderCaptureRegion?
    public let overlaysCursor: Bool

    public init(
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

public struct RenderPixelCapture: Equatable, Sendable {
    public var pixels: [UInt8]
    public let width: Int
    public let height: Int
    public let originX: Int
    public let originY: Int

    public init(
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
public struct RenderSnapshotResource: Equatable, Sendable {
    public let handle: UInt64
    public let width: UInt32
    public let height: UInt32

    public init(handle: UInt64, width: UInt32, height: UInt32) {
        self.handle = handle
        self.width = width
        self.height = height
    }
}

/// The required render service used by the Wayland substrate. All ownership stays
/// on the compositor main actor; GPU captures complete only when the host polls
/// capture work between reactor waits.
@MainActor
public protocol CompositorRenderService: AnyObject {
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
