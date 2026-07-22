#if canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import NucleusRenderer
import NucleusSkiaGraphiteBridge
import NucleusRenderModel

/// The decode queue: the render core's first background thread.
///
/// Tests drive it through real workers rather than a fake clock — the contract
/// under test *is* that work happens on another thread and comes back safely, and
/// a fake would test the fake.
@Suite struct ImageDecodeQueueTests {
    private final class TestWakeSink: AsyncRenderWakeSink, Sendable {
        private let count = Mutex(0)

        nonisolated func signalRenderWork() {
            count.withLock { $0 += 1 }
        }

        var signalCount: Int {
            count.withLock { $0 }
        }
    }

    /// A small PNG written to a temporary file, removed with the test.
    private final class Fixture {
        let path: String

        init(width: Int = 8, height: Int = 8) {
            path = "\(NSTemporaryDirectory())nucleus-queue-"
                + "\(UInt32.random(in: 0...UInt32.max)).png"
            var rgba: [UInt8] = []
            for _ in 0..<(width * height) { rgba.append(contentsOf: [200, 100, 50, 255]) }
            try? PNGWriter.encode(width: width, height: height, rgba: rgba)
                .write(to: URL(fileURLWithPath: path))
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }
    }

    private func source(_ fixture: Fixture) -> ImageSource {
        ImageSource(path: fixture.path, maxWidth: 0, maxHeight: 0)
    }

    /// Drain until something arrives, or give up. Polling rather than blocking:
    /// the render thread drains at frame boundaries and never waits, so the test
    /// exercises the same shape.
    private func waitForDrain(
        _ queue: ImageDecodeQueue, timeout: TimeInterval = 5
    ) -> [DecodedImageResult] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let results = queue.drain()
            if !results.isEmpty { return results }
            usleep(1000)
        }
        return []
    }

    // MARK: - Decoding

    @Test func aSubmittedImageComesBackDecoded() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        let fixture = Fixture()

        #expect(queue.submit(handle: 1, source: source(fixture)))
        let results = waitForDrain(queue)
        #expect(results.count == 1)
        #expect(results.first?.handle == 1)
        #expect(results[0].isValid)
        #expect(results[0].width == 8)
    }

    /// Nothing is ready the instant it is asked for — that is the whole point,
    /// and the caller must be able to cope with an empty drain.
    @Test func drainingBeforeAnythingFinishesYieldsNothing() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        #expect(queue.drain().isEmpty)
    }

    /// A pending decode draws nothing, so the caller asks again every frame.
    /// Without this the queue would fill with duplicates of the same work.
    @Test func resubmittingAPendingHandleIsRefused() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        let fixture = Fixture()

        #expect(queue.submit(handle: 7, source: source(fixture)))
        #expect(!queue.submit(handle: 7, source: source(fixture)))
        #expect(!queue.submit(handle: 7, source: source(fixture)))

        let results = waitForDrain(queue)
        #expect(results.count == 1, "one decode, not three")
    }

    /// Once drained, the handle is forgotten — a re-registered handle must be
    /// decodable again.
    @Test func aHandleCanBeSubmittedAgainAfterDraining() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        let fixture = Fixture()

        #expect(queue.submit(handle: 3, source: source(fixture)))
        _ = waitForDrain(queue)
        #expect(queue.submit(handle: 3, source: source(fixture)))
        #expect(waitForDrain(queue).count == 1)
    }

    @Test func severalImagesAllComeBack() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        let fixtures = (0..<5).map { _ in Fixture() }

        for (index, fixture) in fixtures.enumerated() {
            #expect(queue.submit(handle: UInt64(index + 1), source: source(fixture)))
        }

        var handles: Set<UInt64> = []
        let deadline = Date().addingTimeInterval(10)
        while handles.count < 5 && Date() < deadline {
            for result in queue.drain() { handles.insert(result.handle) }
            usleep(1000)
        }
        #expect(handles == [1, 2, 3, 4, 5])
    }

    /// A file that is not an image fails on the worker and simply never arrives,
    /// rather than delivering an invalid image the render thread would cache.
    @Test func anUndecodableSourceDeliversNothing() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }

        #expect(queue.submit(
            handle: 1, source: ImageSource(path: "/nonexistent", maxWidth: 0, maxHeight: 0)))

        // Nothing should ever arrive; a short wait is enough to say so.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            #expect(queue.drain().isEmpty)
            usleep(2000)
        }
    }

    // MARK: - Completion signal

    /// Nothing else schedules a frame when a decode lands — the scene did not
    /// change, the image simply arrived. Without this the result waits for an
    /// unrelated repaint.
    @Test func completionNotifies() {
        let wakeSink = TestWakeSink()
        let queue = ImageDecodeQueue(wakeSink: wakeSink)
        defer { queue.shutdown() }
        let fixture = Fixture()

        #expect(queue.submit(handle: 1, source: source(fixture)))

        let deadline = Date().addingTimeInterval(5)
        while wakeSink.signalCount == 0 && Date() < deadline { usleep(1000) }
        #expect(wakeSink.signalCount == 1)
        #expect(queue.completionToFrameDemandNanoseconds != nil)
        let generation = queue.completionGeneration
        #expect(generation > 0)
        _ = queue.drain()
        #expect(queue.completionGeneration == generation)
    }

    @Test func aCompletionBurstCoalescesItsWake() {
        let wakeSink = TestWakeSink()
        let queue = ImageDecodeQueue(wakeSink: wakeSink)
        defer { queue.shutdown() }
        let fixtures = (0..<8).map { _ in Fixture() }

        for (index, fixture) in fixtures.enumerated() {
            #expect(queue.submit(handle: UInt64(index + 1), source: source(fixture)))
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if wakeSink.signalCount == 1 {
                usleep(250_000)
                break
            }
            usleep(1000)
        }
        #expect(wakeSink.signalCount == 1)
        #expect(queue.drain().count == fixtures.count)
    }

    @Test func failedDecodeDoesNotWake() {
        let wakeSink = TestWakeSink()
        let queue = ImageDecodeQueue(wakeSink: wakeSink)
        defer { queue.shutdown() }

        #expect(queue.submit(
            handle: 1, source: ImageSource(path: "/nonexistent", maxWidth: 0, maxHeight: 0)))
        usleep(100_000)
        #expect(wakeSink.signalCount == 0)
    }

    // MARK: - Cancellation

    /// An evicted handle may be re-registered for a different source, so a result
    /// in flight for the old one must not be delivered against it.
    @Test func cancellingBeforeDrainDropsTheResult() {
        let wakeSink = TestWakeSink()
        let queue = ImageDecodeQueue(wakeSink: wakeSink)
        defer { queue.shutdown() }
        let fixture = Fixture()

        #expect(queue.submit(handle: 9, source: source(fixture)))
        queue.cancel(handle: 9)

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            #expect(queue.drain().allSatisfy { $0.handle != 9 })
            usleep(2000)
        }
        #expect(wakeSink.signalCount == 0)
    }

    /// Cancelling clears the handle, so the same handle can be submitted again
    /// immediately — which is exactly what a re-registration does.
    @Test func cancellingAllowsResubmission() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        let fixture = Fixture()

        #expect(queue.submit(handle: 4, source: source(fixture)))
        queue.cancel(handle: 4)
        #expect(queue.submit(handle: 4, source: source(fixture)))
    }

    @Test func resubmissionCannotReceiveTheCancelledGeneration() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        let oldFixture = Fixture(width: 256, height: 256)
        let newFixture = Fixture(width: 3, height: 5)

        #expect(queue.submit(handle: 4, source: source(oldFixture)))
        queue.cancel(handle: 4)
        #expect(queue.submit(handle: 4, source: source(newFixture)))

        let results = waitForDrain(queue)
        #expect(results.count == 1)
        #expect(results.first?.width == 3)
        #expect(results.first?.height == 5)
    }

    @Test func cancellingAnUnknownHandleIsHarmless() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        queue.cancel(handle: 999)
    }

    // MARK: - Shutdown

    /// Workers must be stopped before the Graphite context they decode against is
    /// torn down, so shutdown joins rather than merely signalling.
    @Test func shutdownStopsTheWorkers() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        queue.shutdown()
        #expect(!queue.hasWorkers)
        // Submitting after shutdown is refused rather than silently queued
        // forever.
        #expect(!queue.submit(handle: 1, source: ImageSource(path: "/x", maxWidth: 0, maxHeight: 0)))
    }

    @Test func shutdownIsIdempotent() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        queue.shutdown()
        queue.shutdown()
        #expect(!queue.hasWorkers)
    }

    /// Shutting down with work outstanding must not hang or crash.
    @Test func shutdownWithWorkInFlightIsClean() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        let fixtures = (0..<8).map { _ in Fixture(width: 64, height: 64) }
        for (index, fixture) in fixtures.enumerated() {
            queue.submit(handle: UInt64(index + 1), source: source(fixture))
        }
        queue.shutdown()
        #expect(!queue.hasWorkers)
    }

    @Test func deinitStopsWorkersWithoutExplicitShutdown() {
        let wakeSink = TestWakeSink()
        weak var weakQueue: ImageDecodeQueue?
        do {
            var queue: ImageDecodeQueue? = ImageDecodeQueue(wakeSink: wakeSink)
            weakQueue = queue
            let fixture = Fixture(width: 64, height: 64)
            queue?.submit(handle: 1, source: source(fixture))
            queue = nil
        }
        #expect(weakQueue == nil)
    }

    // MARK: - Raw sources

    @Test func rawPixelsDecodeWithoutAFile() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }

        let buffer = RawPixelBuffer(
            width: 2, height: 2, order: .bgra,
            pixels: [UInt8](repeating: 128, count: 16))
        #expect(queue.submit(handle: 1, source: ImageSource(content: .raw(buffer))))

        let results = waitForDrain(queue)
        #expect(results[0].width == 2)
    }

    /// A buffer that does not describe itself consistently yields no image at
    /// all, rather than one built from misread bytes.
    @Test func anInconsistentRawBufferDeliversNothing() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }

        let buffer = RawPixelBuffer(
            width: 64, height: 64, order: .rgba, pixels: [1, 2, 3, 4])
        #expect(queue.submit(handle: 1, source: ImageSource(content: .raw(buffer))))

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            #expect(queue.drain().isEmpty)
            usleep(2000)
        }
    }
}

/// A minimal PNG encoder, so decode tests can state their input rather than ship
/// a binary that hides it.
enum PNGWriter {
    static func encode(width: Int, height: Int, rgba: [UInt8]) -> Data {
        var raw: [UInt8] = []
        for row in 0..<height {
            raw.append(0)
            raw.append(contentsOf: rgba[(row * width * 4)..<((row + 1) * width * 4)])
        }

        var zlib: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let count = min(65535, raw.count - offset)
            zlib.append(offset + count >= raw.count ? 1 : 0)
            zlib.append(contentsOf: [UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF)])
            let inverted = ~UInt16(count)
            zlib.append(contentsOf: [UInt8(inverted & 0xFF), UInt8(inverted >> 8 & 0xFF)])
            zlib.append(contentsOf: raw[offset..<(offset + count)])
            offset += count
        } while offset < raw.count
        zlib.append(contentsOf: beBytes(adler32(raw)))

        var png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        png += chunk("IHDR", beBytes(UInt32(width)) + beBytes(UInt32(height)) + [8, 6, 0, 0, 0])
        png += chunk("IDAT", zlib)
        png += chunk("IEND", [])
        return Data(png)
    }

    private static func beBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let tagged = Array(type.utf8) + payload
        return beBytes(UInt32(payload.count)) + tagged + beBytes(crc32(tagged))
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
