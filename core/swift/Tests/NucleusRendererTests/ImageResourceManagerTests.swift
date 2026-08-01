import Dispatch
internal import NucleusAppHostProtocols
import NucleusRenderModel
import NucleusSkiaGraphiteBridge
import Synchronization
import Testing

@testable import NucleusRenderer

@Suite struct ImageResourceManagerTests {
    private final class TestWakeSink: AsyncRenderWakeSink, Sendable {
        nonisolated func signalRenderWork() {}
    }

    private final class DecodeGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }

    private func source(_ name: String) -> ImageSource {
        ImageSource(path: name, maxWidth: 100, maxHeight: 100)
    }

    private func rawSource(
        width: Int = 2,
        height: Int = 2,
        byte: UInt8 = 0x80
    ) -> ImageSource {
        ImageSource(
            content: .raw(
                RawPixelBuffer(
                    width: width,
                    height: height,
                    order: .rgba,
                    pixels: [UInt8](
                        repeating: byte,
                        count: width * height * 4))))
    }

    /// The returned C++ value owns its raster surface snapshot. The bridge
    /// retains no pointer into Swift storage.
    private func residentImage() -> nucleus.skia.Image {
        unsafe nucleus.skia.makeRasterSurface(1, 1).snapshotImage()
    }

    private func wait(
        for expected: ImageResourcePhase,
        handle: UInt64,
        manager: ImageResourceManager
    ) -> Bool {
        for _ in 0..<5_000 {
            manager.drainCompletions()
            if manager.phase(for: handle) == expected {
                return true
            }
            usleep(1_000)
        }
        return false
    }

    @Test func residencyInvalidatesOnlyConsumersWhenReady() {
        var ledger = ImageResidencyLedger()
        let registered = ledger.registerNew(
            handle: 7,
            source: source("wallpaper"))
        #expect(registered)
        ledger.consume(handle: 7, outputID: 10)
        ledger.consume(handle: 7, outputID: 30)

        let began = ledger.beginDecoding(handle: 7, generation: 1)
        #expect(began)
        let changed = ledger.finishReady(handle: 7, generation: 1)

        #expect(changed == [10, 30])
        #expect(ledger.outputRevision(10) > 0)
        #expect(ledger.outputRevision(20) == 0)
        #expect(
            ledger.outputRevision(30)
                == ledger.outputRevision(10))
    }

    @Test func retryAndReplacementAdvanceGenerationExplicitly() {
        var ledger = ImageResidencyLedger()
        let registered = ledger.registerNew(
            handle: 3,
            source: source("old"))
        #expect(registered)
        let began = ledger.beginDecoding(handle: 3, generation: 1)
        #expect(began)
        ledger.finishFailed(
            handle: 3,
            generation: 1,
            reason: .decodeFailure)

        let retryGeneration = ledger.retry(3)
        #expect(retryGeneration == 2)
        #expect(
            ledger.phase(for: 3)
                == .registered(generation: 2))
        let replacementGeneration = ledger.replace(
            3,
            with: source("new"))
        #expect(replacementGeneration == 3)
        #expect(ledger.source(for: 3) == source("new"))
        #expect(
            ledger.phase(for: 3)
                == .registered(generation: 3))
    }

    @Test func staleTerminalResultsCannotChangeCurrentGeneration() {
        var ledger = ImageResidencyLedger()
        let registered = ledger.registerNew(
            handle: 5,
            source: source("old"))
        #expect(registered)
        let beganOld = ledger.beginDecoding(handle: 5, generation: 1)
        #expect(beganOld)
        let replacementGeneration = ledger.replace(
            5,
            with: source("new"))
        #expect(replacementGeneration == 2)
        let beganNew = ledger.beginDecoding(handle: 5, generation: 2)
        #expect(beganNew)

        let staleReady = ledger.finishReady(
            handle: 5,
            generation: 1)
        let staleFailure = ledger.finishFailed(
            handle: 5,
            generation: 1,
            reason: .decodeFailure)
        #expect(staleReady.isEmpty)
        #expect(staleFailure.isEmpty)
        #expect(
            ledger.phase(for: 5)
                == .decoding(generation: 2))
    }

    @Test func dependencyIdentityIncludesGenerationState() {
        var ledger = ImageResidencyLedger()
        let registeredIcon = ledger.registerNew(
            handle: 3,
            source: source("icon"))
        let registeredPhoto = ledger.registerNew(
            handle: 9,
            source: source("photo"))
        #expect(registeredIcon)
        #expect(registeredPhoto)

        let both = ledger.dependencies(for: [3, 9])
        let iconOnly = ledger.dependencies(for: [3])
        #expect(both != iconOnly)
        #expect(both.versions.map(\.handle) == [3, 9])
    }

    @Test func corruptSourceFailsOnceAcrossRepeatedDraws() {
        let decodeCount = Mutex(0)
        let queue = ImageDecodeQueue(
            wakeSink: TestWakeSink(),
            decodeOperation: { _ in
                decodeCount.withLock { $0 += 1 }
                return .failure(.unsupportedFormat)
            })
        let manager = unsafe ImageResourceManager(
            decodeQueue: queue,
            uploadOperation: { _ in nil })
        defer { manager.shutdown() }
        let corrupt = ImageSource(
            content: .encoded(bytes: [1, 2, 3]),
            maxWidth: 16,
            maxHeight: 16)

        let firstRequestIsPending =
            unsafe manager.image(
                handle: 11,
                source: corrupt,
                outputID: 1) == nil
        #expect(firstRequestIsPending)
        #expect(
            wait(
                for: .failed(
                    generation: 1,
                    reason: .unsupportedFormat),
                handle: 11,
                manager: manager))

        for _ in 0..<100 {
            let repeatedRequestIsPending =
                unsafe manager.image(
                    handle: 11,
                    source: corrupt,
                    outputID: 1) == nil
            #expect(repeatedRequestIsPending)
        }
        #expect(decodeCount.withLock { $0 } == 1)
        #expect(
            manager.failureCounts[.unsupportedFormat]
                == 1)
    }

    @Test func explicitRetryCanTransitionFailureToReady() {
        let decodeCount = Mutex(0)
        let valid = rawSource()
        let queue = ImageDecodeQueue(
            wakeSink: TestWakeSink(),
            decodeOperation: { source in
                let attempt = decodeCount.withLock {
                    $0 += 1
                    return $0
                }
                return attempt == 1
                    ? .failure(.decodeFailure)
                    : ImageDecodeQueue.decode(source)
            })
        let image = unsafe residentImage()
        let manager = unsafe ImageResourceManager(
            decodeQueue: queue,
            uploadOperation: { _ in unsafe image })
        defer { manager.shutdown() }

        _ = unsafe manager.image(handle: 12, source: valid, outputID: 1)
        #expect(
            wait(
                for: .failed(
                    generation: 1,
                    reason: .decodeFailure),
                handle: 12,
                manager: manager))
        #expect(manager.retry(handle: 12))
        _ = unsafe manager.image(handle: 12, source: valid, outputID: 1)
        #expect(
            wait(
                for: .ready(generation: 2),
                handle: 12,
                manager: manager))
        let retryImageIsValid =
            unsafe manager.image(
                handle: 12,
                source: valid,
                outputID: 1)?.isValid() == true
        #expect(retryImageIsValid)
        #expect(decodeCount.withLock { $0 } == 2)
    }

    @Test func replacementRejectsBlockedOldCompletion() {
        let gate = DecodeGate()
        let old = rawSource(width: 8, height: 8, byte: 1)
        let new = rawSource(width: 3, height: 5, byte: 2)
        let queue = ImageDecodeQueue(
            wakeSink: TestWakeSink(),
            workerCount: 2,
            decodeOperation: { source in
                if source == old {
                    gate.entered.signal()
                    gate.release.wait()
                }
                return ImageDecodeQueue.decode(source)
            })
        let image = unsafe residentImage()
        let manager = unsafe ImageResourceManager(
            decodeQueue: queue,
            uploadOperation: { _ in unsafe image })
        defer {
            gate.release.signal()
            manager.shutdown()
        }

        _ = unsafe manager.image(handle: 13, source: old, outputID: 1)
        #expect(gate.entered.wait(timeout: .now() + 2) == .success)
        #expect(manager.replace(handle: 13, with: new))
        _ = unsafe manager.image(handle: 13, source: new, outputID: 1)
        #expect(
            wait(
                for: .ready(generation: 2),
                handle: 13,
                manager: manager))
        gate.release.signal()
        for _ in 0..<100 {
            manager.drainCompletions()
            usleep(1_000)
        }
        #expect(
            manager.phase(for: 13)
                == .ready(generation: 2))
    }

    @Test func evictionDuringDecodeCannotInstallResidentImage() {
        let gate = DecodeGate()
        let source = rawSource()
        let queue = ImageDecodeQueue(
            wakeSink: TestWakeSink(),
            decodeOperation: { source in
                gate.entered.signal()
                gate.release.wait()
                return ImageDecodeQueue.decode(source)
            })
        let image = unsafe residentImage()
        let manager = unsafe ImageResourceManager(
            decodeQueue: queue,
            uploadOperation: { _ in unsafe image })
        defer {
            gate.release.signal()
            manager.shutdown()
        }

        _ = unsafe manager.image(handle: 14, source: source, outputID: 1)
        #expect(gate.entered.wait(timeout: .now() + 2) == .success)
        manager.evict(14)
        gate.release.signal()
        for _ in 0..<100 {
            manager.drainCompletions()
            usleep(1_000)
        }
        #expect(manager.phase(for: 14) == nil)
        #expect(manager.residency(for: 14) == .unknown)
    }

    @Test func uploadWorkIsBoundedAndReadyDrawDoesNotDecode() {
        let decodeCount = Mutex(0)
        let uploadCount = Mutex(0)
        let queue = ImageDecodeQueue(
            wakeSink: TestWakeSink(),
            workerCount: 2,
            decodeOperation: { source in
                decodeCount.withLock { $0 += 1 }
                return ImageDecodeQueue.decode(source)
            })
        let image = unsafe residentImage()
        let manager = unsafe ImageResourceManager(
            decodeQueue: queue,
            uploadOperation: { _ in
                uploadCount.withLock { $0 += 1 }
                return unsafe image
            })
        defer { manager.shutdown() }

        let sources = (1...10).map {
            rawSource(byte: UInt8($0))
        }
        for (index, source) in sources.enumerated() {
            _ = unsafe manager.image(
                handle: UInt64(index + 1),
                source: source,
                outputID: 1)
        }
        for _ in 0..<5_000
        where decodeCount.withLock({ $0 }) < sources.count {
            usleep(1_000)
        }

        manager.drainCompletions()
        #expect(uploadCount.withLock { $0 } <= 4)
        while uploadCount.withLock({ $0 }) < sources.count {
            manager.drainCompletions()
        }
        let beforeDraw = decodeCount.withLock { $0 }
        let readyImageIsValid =
            unsafe manager.image(
                handle: 1,
                source: sources[0],
                outputID: 1)?.isValid() == true
        #expect(readyImageIsValid)
        #expect(decodeCount.withLock { $0 } == beforeDraw)
    }

    @Test func evictionTargetsConsumersAndDropsState() {
        var ledger = ImageResidencyLedger()
        let registered = ledger.registerNew(
            handle: 4,
            source: source("wallpaper"))
        #expect(registered)
        ledger.consume(handle: 4, outputID: 2)
        let began = ledger.beginDecoding(handle: 4, generation: 1)
        #expect(began)
        ledger.finishReady(handle: 4, generation: 1)
        let before = ledger.outputRevision(2)

        let evicted = ledger.evict(4)
        #expect(evicted == [2])
        #expect(ledger.phase(for: 4) == nil)
        #expect(ledger.outputRevision(2) > before)
    }
}
