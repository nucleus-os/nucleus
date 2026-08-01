import Dispatch
import Foundation
internal import NucleusAppHostProtocols
import NucleusRenderModel
import Synchronization
import Testing

@testable import NucleusRenderer

#if canImport(Glibc)
import Glibc
#endif

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

    private final class Fixture {
        let path: String
        let width: Int
        let height: Int

        init(width: Int = 8, height: Int = 8) {
            self.width = width
            self.height = height
            path =
                "\(NSTemporaryDirectory())nucleus-queue-"
                + "\(UInt32.random(in: 0...UInt32.max)).png"
            let rgba = [UInt8](
                repeating: 0x80,
                count: width * height * 4)
            try? PNGWriter.encode(
                width: width,
                height: height,
                rgba: rgba
            ).write(to: URL(fileURLWithPath: path))
        }

        deinit {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private final class DecodeGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }

    private func source(_ fixture: Fixture) -> ImageSource {
        ImageSource(
            path: fixture.path,
            maxWidth: UInt32(fixture.width),
            maxHeight: UInt32(fixture.height))
    }

    private func waitForDrain(
        _ queue: ImageDecodeQueue,
        minimumCount: Int = 1,
        timeout: TimeInterval = 5
    ) -> [ImageDecodeCompletion] {
        let deadline = Date().addingTimeInterval(timeout)
        var completions: [ImageDecodeCompletion] = []
        while completions.count < minimumCount && Date() < deadline {
            completions.append(contentsOf: queue.drain())
            if completions.count < minimumCount {
                usleep(1_000)
            }
        }
        return completions
    }

    private func failure(
        _ result: Result<DecodedImage, ImageDecodeFailure>
    ) -> ImageDecodeFailure? {
        guard case .failure(let reason) = result else { return nil }
        return reason
    }

    @Test func aSubmittedGenerationReturnsDecodedPixels() throws {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        let fixture = Fixture()

        #expect(
            queue.submit(
                handle: 1,
                generation: 7,
                source: source(fixture)))
        let completion = try #require(waitForDrain(queue).first)
        #expect(completion.handle == 1)
        #expect(completion.generation == 7)
        let decoded = try completion.result.get()
        #expect(decoded.isValid)
        #expect(decoded.width == 8)
        #expect(decoded.height == 8)
    }

    @Test func duplicateHandleGenerationIsCoalesced() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        let fixture = Fixture(width: 128, height: 128)

        #expect(
            queue.submit(
                handle: 3,
                generation: 1,
                source: source(fixture)))
        #expect(
            !queue.submit(
                handle: 3,
                generation: 1,
                source: source(fixture)))
        #expect(waitForDrain(queue).count == 1)
    }

    @Test func corruptBytesProduceOneTypedFailure() throws {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        defer { queue.shutdown() }
        let source = ImageSource(
            content: .encoded(bytes: [0xDE, 0xAD, 0xBE, 0xEF]),
            maxWidth: 32,
            maxHeight: 32)

        #expect(queue.submit(handle: 9, generation: 1, source: source))
        #expect(!queue.submit(handle: 9, generation: 1, source: source))
        let completion = try #require(waitForDrain(queue).first)
        #expect(failure(completion.result) == .unsupportedFormat)
        #expect(queue.drain().isEmpty)
    }

    @Test func missingFileProducesUnreadableCompletionAndWake() throws {
        let wakeSink = TestWakeSink()
        let queue = ImageDecodeQueue(wakeSink: wakeSink)
        defer { queue.shutdown() }

        #expect(
            queue.submit(
                handle: 2,
                generation: 1,
                source: ImageSource(
                    path: "/definitely/missing/nucleus.png",
                    maxWidth: 32,
                    maxHeight: 32)))
        let completion = try #require(waitForDrain(queue).first)
        #expect(failure(completion.result) == .unreadableInput)
        #expect(wakeSink.signalCount == 1)
    }

    @Test func cancellationIsATerminalCompletion() throws {
        let gate = DecodeGate()
        let queue = ImageDecodeQueue(
            wakeSink: TestWakeSink(),
            decodeOperation: { source in
                gate.entered.signal()
                gate.release.wait()
                return ImageDecodeQueue.decode(source)
            })
        defer {
            gate.release.signal()
            queue.shutdown()
        }
        let fixture = Fixture()
        #expect(
            queue.submit(
                handle: 4,
                generation: 1,
                source: source(fixture)))
        #expect(gate.entered.wait(timeout: .now() + 2) == .success)
        queue.cancel(handle: 4)
        gate.release.signal()

        let completion = try #require(waitForDrain(queue).first)
        #expect(failure(completion.result) == .cancellation)
    }

    @Test func runningOldGenerationAndNewGenerationBothTerminate()
        throws
    {
        let gate = DecodeGate()
        let queue = ImageDecodeQueue(
            wakeSink: TestWakeSink(),
            decodeOperation: { source in
                gate.entered.signal()
                gate.release.wait()
                return ImageDecodeQueue.decode(source)
            })
        defer {
            gate.release.signal()
            gate.release.signal()
            queue.shutdown()
        }
        let old = Fixture(width: 16, height: 16)
        let new = Fixture(width: 3, height: 5)
        #expect(
            queue.submit(
                handle: 5,
                generation: 1,
                source: source(old)))
        #expect(gate.entered.wait(timeout: .now() + 2) == .success)
        #expect(
            queue.submit(
                handle: 5,
                generation: 2,
                source: source(new)))
        gate.release.signal()
        #expect(gate.entered.wait(timeout: .now() + 2) == .success)
        gate.release.signal()

        let completions = waitForDrain(queue, minimumCount: 2)
        #expect(Set(completions.map(\.generation)) == [1, 2])
        let newest = try #require(
            completions.first { $0.generation == 2 })
        let decoded = try newest.result.get()
        #expect(decoded.width == 3)
        #expect(decoded.height == 5)
    }

    @Test func supersedingPendingGenerationSignalsItsCancellation()
        throws
    {
        let gate = DecodeGate()
        let wakeSink = TestWakeSink()
        let queue = ImageDecodeQueue(
            wakeSink: wakeSink,
            decodeOperation: { source in
                gate.entered.signal()
                gate.release.wait()
                return ImageDecodeQueue.decode(source)
            })
        defer {
            gate.release.signal()
            gate.release.signal()
            queue.shutdown()
        }
        let blocker = Fixture()
        let old = Fixture()
        let new = Fixture()
        #expect(
            queue.submit(
                handle: 41,
                generation: 1,
                source: source(blocker)))
        #expect(gate.entered.wait(timeout: .now() + 2) == .success)
        #expect(
            queue.submit(
                handle: 42,
                generation: 1,
                source: source(old)))
        #expect(
            queue.submit(
                handle: 42,
                generation: 2,
                source: source(new)))

        let completion = try #require(queue.drain().first)
        #expect(completion.handle == 42)
        #expect(completion.generation == 1)
        #expect(failure(completion.result) == .cancellation)
        #expect(wakeSink.signalCount == 1)
    }

    @Test func zeroBoundsAreInvalidRatherThanDeferred() {
        let fixture = Fixture()
        #expect(
            failure(
                ImageDecodeQueue.decode(
                    ImageSource(
                        path: fixture.path,
                        maxWidth: 0,
                        maxHeight: 8))
            ) == .invalidDimensions)
    }

    @Test func oversizedTargetDimensionFailsBeforeDecode() {
        let fixture = Fixture()
        #expect(
            failure(
                ImageDecodeQueue.decode(
                    ImageSource(
                        path: fixture.path,
                        maxWidth: 32_769,
                        maxHeight: 1))
            ) == .limitExceeded)
    }

    @Test func oversizedPixelCountFailsBeforeDecode() {
        let fixture = Fixture()
        #expect(
            failure(
                ImageDecodeQueue.decode(
                    ImageSource(
                        path: fixture.path,
                        maxWidth: 10_000,
                        maxHeight: 10_000))
            ) == .limitExceeded)
    }

    @Test func oversizedSvgTargetFailsBeforeRasterization() {
        let bytes = Array(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>
            """.utf8)
        #expect(
            failure(
                ImageDecodeQueue.decode(
                    ImageSource(
                        content: .encoded(bytes: bytes),
                        maxWidth: 32_769,
                        maxHeight: 1))
            ) == .limitExceeded)
    }

    @Test func rawByteCountOverflowFailsBeforeNormalization() {
        let buffer = RawPixelBuffer(
            width: Int.max,
            height: Int.max,
            rowStride: Int.max,
            order: .rgba,
            pixels: [0, 0, 0, 0])
        #expect(
            failure(
                ImageDecodeQueue.decode(ImageSource(content: .raw(buffer)))
            ) == .limitExceeded)
    }

    @Test func encodedInputLimitIsEnforced() {
        let bytes = [UInt8](
            repeating: 0,
            count: 64 * 1024 * 1024 + 1)
        #expect(
            failure(
                ImageDecodeQueue.decode(
                    ImageSource(
                        content: .encoded(bytes: bytes),
                        maxWidth: 1,
                        maxHeight: 1))
            ) == .limitExceeded)
    }

    @Test func metadataProbeReadsIntrinsicDimensionsWithoutDecode()
        throws
    {
        let fixture = Fixture(width: 13, height: 17)
        let metadata = try ImageDecodeQueue.probeMetadata(
            source(fixture)
        ).get()
        #expect(metadata.width == 13)
        #expect(metadata.height == 17)
        #expect(!metadata.isVector)
    }

    @Test func rawPixelsDecodeToOwnedRasterPixels() throws {
        let source = ImageSource(
            content: .raw(
                RawPixelBuffer(
                    width: 2,
                    height: 3,
                    order: .bgra,
                    pixels: [UInt8](repeating: 0x80, count: 24))))
        let decoded = try ImageDecodeQueue.decode(source).get()
        #expect(decoded.width == 2)
        #expect(decoded.height == 3)
    }

    @Test func shutdownRefusesNewWork() {
        let queue = ImageDecodeQueue(wakeSink: TestWakeSink())
        queue.shutdown()
        #expect(!queue.hasWorkers)
        #expect(
            !queue.submit(
                handle: 1,
                generation: 1,
                source: ImageSource(
                    content: .raw(
                        RawPixelBuffer(
                            width: 1,
                            height: 1,
                            order: .rgba,
                            pixels: [0, 0, 0, 0])))))
    }

    @Test func shutdownReturnsTerminalCancellationForEveryOutstandingJob()
        throws
    {
        let gate = DecodeGate()
        let queue = ImageDecodeQueue(
            wakeSink: TestWakeSink(),
            decodeOperation: { source in
                gate.entered.signal()
                gate.release.wait()
                return ImageDecodeQueue.decode(source)
            })
        let running = Fixture()
        let pending = Fixture()
        #expect(
            queue.submit(
                handle: 51,
                generation: 1,
                source: source(running)))
        #expect(gate.entered.wait(timeout: .now() + 2) == .success)
        #expect(
            queue.submit(
                handle: 52,
                generation: 1,
                source: source(pending)))
        DispatchQueue.global().async {
            usleep(10_000)
            gate.release.signal()
        }

        let completions = queue.shutdown()
        #expect(Set(completions.map(\.handle)) == [51, 52])
        #expect(
            completions.allSatisfy {
                failure($0.result) == .cancellation
            })
    }
}

enum PNGWriter {
    static func encode(
        width: Int,
        height: Int,
        rgba: [UInt8]
    ) -> Data {
        var raw: [UInt8] = []
        for row in 0..<height {
            raw.append(0)
            raw.append(
                contentsOf:
                    rgba[(row * width * 4)..<((row + 1) * width * 4)])
        }

        var zlib: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let count = min(65_535, raw.count - offset)
            zlib.append(offset + count >= raw.count ? 1 : 0)
            zlib.append(contentsOf: [
                UInt8(count & 0xFF),
                UInt8(count >> 8 & 0xFF),
            ])
            let inverted = ~UInt16(count)
            zlib.append(contentsOf: [
                UInt8(inverted & 0xFF),
                UInt8(inverted >> 8 & 0xFF),
            ])
            zlib.append(contentsOf: raw[offset..<(offset + count)])
            offset += count
        } while offset < raw.count
        zlib.append(contentsOf: beBytes(adler32(raw)))

        var png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        png += chunk(
            "IHDR",
            beBytes(UInt32(width))
                + beBytes(UInt32(height))
                + [8, 6, 0, 0, 0])
        png += chunk("IDAT", zlib)
        png += chunk("IEND", [])
        return Data(png)
    }

    private static func beBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value >> 24 & 0xFF),
            UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static func chunk(
        _ type: String,
        _ payload: [UInt8]
    ) -> [UInt8] {
        let tagged = Array(type.utf8) + payload
        return beBytes(UInt32(payload.count))
            + tagged
            + beBytes(crc32(tagged))
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc =
                    (crc & 1) != 0
                    ? (crc >> 1) ^ 0xEDB8_8320
                    : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
