import Glibc
import Testing
import NucleusCompositorServer
@testable import NucleusCompositorWaylandRuntime

@MainActor
final class RenderServiceSpy: CompositorRenderService {
    struct ShmSnapshot: Equatable {
        var previousIOSurfaceID: UInt32
        var width: UInt32
        var height: UInt32
        var drmFormat: UInt32
        var stride: UInt32
        var pixels: [UInt8]
    }

    var shmSnapshot: ShmSnapshot?
    var dmabufImport: RenderDmabufImport?
    var dmabufProbe: RenderDmabufProbe?
    var gammaRamp: RenderGammaRamp?
    var clearedOutputID: UInt64?
    var forcedOutputIDs: [UInt64] = []
    var destroyedTimelineHandles: [UInt32] = []
    var dmabufCapture: RenderDmabufCapture?
    var releasedSnapshotHandles: [UInt64] = []
    var capturedSnapshotIOSurfaceIDs: [UInt32] = []

    var presentationClockID: UInt32 = 7
    var dmabufMainDevice: UInt64 = 9
    var liveSnapshotCount: Int = 0

    func importShm(_ request: RenderShmImport) -> UInt32 {
        shmSnapshot = ShmSnapshot(
            previousIOSurfaceID: request.previousIOSurfaceID,
            width: request.width,
            height: request.height,
            drmFormat: request.drmFormat,
            stride: request.stride,
            pixels: Array(request.pixels))
        return 41
    }

    func importDmabuf(_ request: RenderDmabufImport) -> UInt32 {
        dmabufImport = request
        return 42
    }

    func releaseIOSurface(_: UInt32) {}

    func dmabufFormats() -> [RenderDmabufFormat] {
        [
            RenderDmabufFormat(format: 0x3432_5258, modifier: 11),
            RenderDmabufFormat(format: 0x3432_5241, modifier: 12),
        ]
    }

    func probeDmabuf(_ request: RenderDmabufProbe) -> Bool {
        dmabufProbe = request
        return true
    }

    func gammaRampSize(outputID _: UInt64) -> UInt32 { 256 }

    func applyGamma(_ ramp: RenderGammaRamp) -> Bool {
        gammaRamp = ramp
        return true
    }

    func clearGamma(outputID: UInt64) {
        clearedOutputID = outputID
    }

    func forcePresent(outputID: UInt64) {
        forcedOutputIDs.append(outputID)
    }

    func importSyncobjTimeline(fd: Int32) -> UInt32? {
        UInt32(bitPattern: fd)
    }

    func destroySyncobjTimeline(handle: UInt32) {
        destroyedTimelineHandles.append(handle)
    }

    func beginCaptureOutput(
        outputID _: UInt64,
        sourceRegion _: RenderCaptureRegion?,
        completion: @escaping @MainActor (RenderPixelCapture?) -> Void
    ) -> UInt64? {
        completion(RenderPixelCapture(
            pixels: [1, 2, 3, 4], width: 1, height: 1))
        return 1
    }

    func beginReadSurface(
        iosurfaceID _: UInt32,
        completion: @escaping @MainActor (RenderPixelCapture?) -> Void
    ) -> UInt64? {
        completion(RenderPixelCapture(
            pixels: [5, 6, 7, 8], width: 1, height: 1))
        return 2
    }

    func beginCaptureOutput(
        to request: RenderDmabufCapture,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> UInt64? {
        dmabufCapture = request
        completion(true)
        return 3
    }

    var hasPendingCaptureWork: Bool { false }
    var capturePollDelay: UInt64? { nil }
    var captureWorkStalled: Bool { false }
    func pollCaptureWork() {}
    func cancelCapture(_: UInt64) {}

    func captureSurfaceSnapshot(
        iosurfaceID: UInt32
    ) -> RenderSnapshotResource? {
        guard iosurfaceID != 0 else { return nil }
        capturedSnapshotIOSurfaceIDs.append(iosurfaceID)
        liveSnapshotCount += 1
        return RenderSnapshotResource(
            handle: UInt64(iosurfaceID) + 1_000,
            width: 10,
            height: 20)
    }

    func releaseSnapshot(_ handle: UInt64) {
        releasedSnapshotHandles.append(handle)
        liveSnapshotCount -= 1
    }
}

@MainActor
@Test func typedRenderServicePreservesValuesAndBorrowedOwnership() {
    let server = NucleusCompositorServer.shared
    server.renderService = nil
    defer { server.renderService = nil }

    let driver = RouterRenderDriver()
    #expect(driver.presentationClockId == UInt32(CLOCK_MONOTONIC))
    #expect(driver.dmabufSupportedFormats().isEmpty)
    #expect(driver.importSyncobjTimeline(fd: 17) == nil)

    var firstPipe = [Int32](repeating: -1, count: 2)
    var secondPipe = [Int32](repeating: -1, count: 2)
    #expect(pipe(&firstPipe) == 0)
    #expect(pipe(&secondPipe) == 0)
    defer {
        close(firstPipe[1])
        close(secondPipe[1])
    }

    let attrs = DmabufAttrs(
        width: 640,
        height: 480,
        format: 0x3432_5258,
        modifier: 99,
        planes: [
            DmabufPlane(
                consumingFd: firstPipe[0],
                offset: 4,
                stride: 2_560),
            DmabufPlane(
                consumingFd: secondPipe[0],
                offset: 8,
                stride: 1_280),
        ])
    #expect(!driver.dmabufImport(attrs))

    let spy = RenderServiceSpy()
    server.renderService = spy

    var shmPixels: [UInt8] = [10, 20, 30, 40, 50, 60, 70, 80]
    let shmID = shmPixels.withUnsafeBytes {
        spy.importShm(
            RenderShmImport(
                previousIOSurfaceID: 37,
                width: 2,
                height: 1,
                drmFormat: 0x3432_5241,
                stride: 8,
                pixels: $0))
    }
    shmPixels[0] = 0
    #expect(shmID == 41)
    #expect(spy.shmSnapshot == .init(
        previousIOSurfaceID: 37,
        width: 2,
        height: 1,
        drmFormat: 0x3432_5241,
        stride: 8,
        pixels: [10, 20, 30, 40, 50, 60, 70, 80]))

    let importRequest = RouterSurfaceSceneDriver.renderDmabufImport(
        previousIOSurfaceID: 38,
        attrs: attrs,
        acquire: SyncPoint(handle: 101, point: 102),
        release: SyncPoint(handle: 201, point: 202))
    #expect(spy.importDmabuf(importRequest) == 42)
    #expect(spy.dmabufImport == RenderDmabufImport(
        previousIOSurfaceID: 38,
        width: 640,
        height: 480,
        drmFormat: 0x3432_5258,
        modifier: 99,
        planes: [
            RenderDmabufPlane(
                fd: firstPipe[0], offset: 4, stride: 2_560),
            RenderDmabufPlane(
                fd: secondPipe[0], offset: 8, stride: 1_280),
        ],
        acquire: RenderSyncPoint(handle: 101, point: 102),
        release: RenderSyncPoint(handle: 201, point: 202)))

    #expect(driver.dmabufImport(attrs))
    #expect(spy.dmabufProbe == RenderDmabufProbe(
        width: 640,
        height: 480,
        drmFormat: 0x3432_5258,
        modifier: 99,
        planes: [
            RenderDmabufPlane(
                fd: firstPipe[0], offset: 4, stride: 2_560),
            RenderDmabufPlane(
                fd: secondPipe[0], offset: 8, stride: 1_280),
        ]))
    #expect(fcntl(firstPipe[0], F_GETFD) >= 0)
    #expect(fcntl(secondPipe[0], F_GETFD) >= 0)

    #expect(driver.presentationClockId == 7)
    #expect(driver.dmabufMainDevice() == 9)
    #expect(driver.dmabufSupportedFormats() == [
        DmabufFormat(format: 0x3432_5258, modifier: 11),
        DmabufFormat(format: 0x3432_5241, modifier: 12),
    ])
    #expect(driver.gammaRampSize(output: nil) == 256)
    driver.gammaApply(
        output: nil,
        red: [1, 2],
        green: [3, 4],
        blue: [5, 6])
    #expect(spy.gammaRamp == RenderGammaRamp(
        outputID: 0,
        red: [1, 2],
        green: [3, 4],
        blue: [5, 6]))
    driver.gammaClear(output: nil)
    #expect(spy.clearedOutputID == 0)
    #expect(driver.importSyncobjTimeline(fd: 17) == 17)
    driver.destroySyncobjTimeline(handle: 88)
    #expect(spy.destroyedTimelineHandles == [88])

    let region = RenderCaptureRegion(
        x: 3, y: 5, width: 320, height: 200)
    let captureRequest = RouterRenderDriver.renderDmabufCapture(
        outputID: 73,
        attrs: attrs,
        sourceRegion: region,
        overlaysCursor: true)
    var captureSucceeded = false
    #expect(spy.beginCaptureOutput(to: captureRequest) {
        captureSucceeded = $0
    } != nil)
    #expect(captureSucceeded)
    #expect(spy.dmabufCapture == RenderDmabufCapture(
        outputID: 73,
        width: 640,
        height: 480,
        drmFormat: 0x3432_5258,
        modifier: 99,
        planes: [
            RenderDmabufPlane(
                fd: firstPipe[0], offset: 4, stride: 2_560),
            RenderDmabufPlane(
                fd: secondPipe[0], offset: 8, stride: 1_280),
        ],
        sourceRegion: region,
        overlaysCursor: true))
}

@MainActor
@Test func serverDoesNotOwnRenderServiceLifetime() {
    let server = NucleusCompositorServer.shared
    server.renderService = nil
    #expect(server.renderService == nil)

    weak var releasedService: RenderServiceSpy?
    do {
        let service = RenderServiceSpy()
        releasedService = service
        server.renderService = service
        #expect(server.renderService === service)
    }

    #expect(releasedService == nil)
    #expect(server.renderService == nil)
}
