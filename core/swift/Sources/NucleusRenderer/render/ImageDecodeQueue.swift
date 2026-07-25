#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif
package import NucleusRenderModel
import NucleusSkiaGraphiteBridge
import Tracy

@_spi(NucleusPlatform)
public enum ImageDecodeFailure: Error, Sendable, Equatable, Hashable {
    case unreadableInput
    case unsupportedFormat
    case invalidDimensions
    case limitExceeded
    case decodeFailure
    case cancellation
    case uploadFailure
}

package struct DecodedImage: @unchecked Sendable {
    package var image: nucleus.skia.RasterImage

    package var isValid: Bool { image.isValid() }
    package var width: Int32 { image.width() }
    package var height: Int32 { image.height() }
}

package struct ImageDecodeCompletion: @unchecked Sendable {
    package var handle: UInt64
    package var generation: UInt64
    package var result: Result<DecodedImage, ImageDecodeFailure>
}

package struct ImageMetadata: Sendable, Equatable {
    package var width: Int32
    package var height: Int32
    package var isVector: Bool
}

/// A generation-aware eager-decode queue.
///
/// Workers return one typed terminal completion for every job they start or
/// cancel. No encoded object crosses back to the render thread: success owns
/// immutable CPU pixels and upload remains an explicitly budgeted render-owner
/// operation.
package final class ImageDecodeQueue {
    package typealias DecodeOperation =
        @Sendable (ImageSource) -> Result<DecodedImage, ImageDecodeFailure>

    private struct JobKey: Hashable, Sendable {
        var handle: UInt64
        var generation: UInt64
    }

    private final class WorkerState: @unchecked Sendable {
        private struct Request: Sendable {
            var key: JobKey
            var source: ImageSource
        }

        private var pending: [Request] = []
        private var pendingHead = 0
        private var runningJobs: Set<JobKey> = []
        private var cancelledJobs: Set<JobKey> = []
        private var submittedJobs: Set<JobKey> = []
        private var completed: [ImageDecodeCompletion] = []
        private var running = true
        private var latestCompletionToFrameDemandNs: UInt64?

        private let synchronization = BlockingSynchronization()
        private let wakeSink: any AsyncRenderWakeSink
        private let decodeOperation: DecodeOperation
        private let clock = ContinuousClock()

        init(
            wakeSink: any AsyncRenderWakeSink,
            decodeOperation: @escaping DecodeOperation
        ) {
            self.wakeSink = wakeSink
            self.decodeOperation = decodeOperation
        }

        func submit(
            handle: UInt64,
            generation: UInt64,
            source: ImageSource
        ) -> Bool {
            let key = JobKey(handle: handle, generation: generation)
            return synchronization.withLock {
                guard running, handle != 0, generation != 0,
                      !submittedJobs.contains(key)
                else { return false }

                // A newer generation supersedes only non-started work. Running
                // work completes normally and is rejected as stale by its owner.
                if pendingHead < pending.count {
                    var retained = Array(pending[pendingHead...])
                    for request in retained
                    where request.key.handle == handle
                        && request.key != key
                    {
                        appendCompletion(
                            key: request.key,
                            result: .failure(.cancellation))
                    }
                    retained.removeAll {
                        $0.key.handle == handle && $0.key != key
                    }
                    pending = retained
                    pendingHead = 0
                } else {
                    pending.removeAll(keepingCapacity: true)
                    pendingHead = 0
                }

                submittedJobs.insert(key)
                pending.append(Request(key: key, source: source))
                synchronization.signal()
                return true
            }
        }

        func drain(maxCount: Int) -> [ImageDecodeCompletion] {
            synchronization.withLock {
                guard maxCount > 0, !completed.isEmpty else { return [] }
                let count = min(maxCount, completed.count)
                let results = Array(completed.prefix(count))
                completed.removeFirst(count)
                for completion in results {
                    submittedJobs.remove(JobKey(
                        handle: completion.handle,
                        generation: completion.generation))
                }
                return results
            }
        }

        func cancel(handle: UInt64) {
            let shouldWake = synchronization.withLock {
                let wasEmpty = completed.isEmpty
                if pendingHead < pending.count {
                    var retained = Array(pending[pendingHead...])
                    for request in retained where request.key.handle == handle {
                        appendCompletion(
                            key: request.key,
                            result: .failure(.cancellation))
                    }
                    retained.removeAll { $0.key.handle == handle }
                    pending = retained
                    pendingHead = 0
                } else {
                    pending.removeAll(keepingCapacity: true)
                    pendingHead = 0
                }
                for key in runningJobs where key.handle == handle {
                    cancelledJobs.insert(key)
                }
                return wasEmpty && !completed.isEmpty
            }
            if shouldWake {
                signalCompletion()
            }
        }

        func stop() -> Bool {
            synchronization.withLock {
                guard running else { return false }
                running = false
                pending.removeAll()
                pendingHead = 0
                synchronization.broadcast()
                return true
            }
        }

        func completionToFrameDemandNanoseconds() -> UInt64? {
            synchronization.withLock {
                latestCompletionToFrameDemandNs
            }
        }

        func workerLoop() {
            while true {
                synchronization.lock()
                while running && pendingHead == pending.count {
                    if pendingHead != 0 {
                        pending.removeAll(keepingCapacity: true)
                        pendingHead = 0
                    }
                    synchronization.wait()
                }
                guard running else {
                    synchronization.unlock()
                    return
                }
                let request = pending[pendingHead]
                pendingHead += 1
                runningJobs.insert(request.key)
                compactPendingIfNeeded()
                synchronization.unlock()

                let decoded = decodeOperation(request.source)

                let shouldWake = synchronization.withLock {
                    runningJobs.remove(request.key)
                    let terminal: Result<DecodedImage, ImageDecodeFailure>
                    if cancelledJobs.remove(request.key) != nil {
                        terminal = .failure(.cancellation)
                    } else {
                        terminal = decoded
                    }
                    let wasEmpty = completed.isEmpty
                    appendCompletion(key: request.key, result: terminal)
                    return running && wasEmpty
                }
                if shouldWake {
                    signalCompletion()
                }
            }
        }

        private func appendCompletion(
            key: JobKey,
            result: Result<DecodedImage, ImageDecodeFailure>
        ) {
            completed.append(ImageDecodeCompletion(
                handle: key.handle,
                generation: key.generation,
                result: result))
        }

        private func signalCompletion() {
            let completionInstant = clock.now
            wakeSink.signalRenderWork()
            let latency = elapsedNanoseconds(completionInstant, clock.now)
            synchronization.withLock {
                latestCompletionToFrameDemandNs = latency
            }
            Trace.plot(
                "swift.renderer.image_decode.completion_to_frame_demand_ns",
                latency)
        }

        private func compactPendingIfNeeded() {
            guard pendingHead >= 64, pendingHead * 2 >= pending.count else {
                return
            }
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
    }

    private var state: WorkerState?
    private var workers: [pthread_t] = []

    package init(
        wakeSink: any AsyncRenderWakeSink,
        workerCount: Int = 1,
        decodeOperation: @escaping DecodeOperation = ImageDecodeQueue.decode
    ) {
        let state = WorkerState(
            wakeSink: wakeSink,
            decodeOperation: decodeOperation)
        self.state = state
        for _ in 0..<max(0, workerCount) {
            let retainedState =
                Unmanaged.passRetained(state).toOpaque()
            var thread = pthread_t()
            let created = pthread_create(&thread, nil, { pointer in
                let state = Unmanaged<WorkerState>
                    .fromOpaque(pointer!)
                    .takeRetainedValue()
                state.workerLoop()
                return nil
            }, retainedState)
            if created == 0 {
                workers.append(thread)
            } else {
                Unmanaged<WorkerState>
                    .fromOpaque(retainedState)
                    .release()
            }
        }
    }

    deinit {
        shutdown()
    }

    package var hasWorkers: Bool { !workers.isEmpty }

    package var completionToFrameDemandNanoseconds: UInt64? {
        state?.completionToFrameDemandNanoseconds()
    }

    @discardableResult
    package func submit(
        handle: UInt64,
        generation: UInt64,
        source: ImageSource
    ) -> Bool {
        guard hasWorkers, let state else { return false }
        return state.submit(
            handle: handle,
            generation: generation,
            source: source)
    }

    package func drain(
        maxCount: Int = .max
    ) -> [ImageDecodeCompletion] {
        state?.drain(maxCount: maxCount) ?? []
    }

    package func cancel(handle: UInt64) {
        state?.cancel(handle: handle)
    }

    package func shutdown() {
        guard let state, state.stop() else { return }
        for thread in workers {
            pthread_join(thread, nil)
        }
        workers.removeAll()
        self.state = nil
    }

    package static func probeMetadata(
        _ source: ImageSource
    ) -> Result<ImageMetadata, ImageDecodeFailure> {
        switch source.content {
        case .raw(let buffer):
            guard let dimensions = validatedDimensions(
                width: buffer.width,
                height: buffer.height,
                bytesPerPixel: 4)
            else { return .failure(.limitExceeded) }
            guard buffer.isWellFormed else {
                return .failure(.invalidDimensions)
            }
            return .success(ImageMetadata(
                width: dimensions.width,
                height: dimensions.height,
                isVector: false))
        case .file(let path):
            guard encodedFileSize(path) != nil else {
                return .failure(.unreadableInput)
            }
            return mapMetadata(
                nucleus.skia.probeEncodedImageFile(path))
        case .encoded(let bytes):
            guard !bytes.isEmpty else {
                return .failure(.unreadableInput)
            }
            guard bytes.count <= Limits.maximumEncodedBytes else {
                return .failure(.limitExceeded)
            }
            return bytes.withUnsafeBufferPointer {
                mapMetadata(nucleus.skia.probeEncodedImageMemory(
                    $0.baseAddress,
                    $0.count))
            }
        }
    }

    package static func decode(
        _ source: ImageSource
    ) -> Result<DecodedImage, ImageDecodeFailure> {
        switch source.content {
        case .file(let path):
            guard let size = encodedFileSize(path) else {
                return .failure(.unreadableInput)
            }
            guard size <= Limits.maximumEncodedBytes else {
                return .failure(.limitExceeded)
            }
            guard let bounds = validatedTargetBounds(source) else {
                return .failure(targetFailure(source))
            }
            return mapDecode(nucleus.skia.decodeEncodedImageFile(
                path,
                bounds.width,
                bounds.height))
        case .encoded(let bytes):
            guard !bytes.isEmpty else {
                return .failure(.unreadableInput)
            }
            guard bytes.count <= Limits.maximumEncodedBytes else {
                return .failure(.limitExceeded)
            }
            guard let bounds = validatedTargetBounds(source) else {
                return .failure(targetFailure(source))
            }
            return bytes.withUnsafeBufferPointer {
                mapDecode(nucleus.skia.decodeEncodedImageMemory(
                    $0.baseAddress,
                    $0.count,
                    bounds.width,
                    bounds.height))
            }
        case .raw(let buffer):
            guard buffer.width > 0, buffer.height > 0 else {
                return .failure(.invalidDimensions)
            }
            guard validatedDimensions(
                width: buffer.width,
                height: buffer.height,
                bytesPerPixel: 4) != nil
            else { return .failure(.limitExceeded) }
            guard let rgba = buffer.normalizedRGBA() else {
                return .failure(.decodeFailure)
            }
            let image = rgba.withUnsafeBufferPointer {
                nucleus.skia.makeRasterImageRGBA(
                    Int32(buffer.width),
                    Int32(buffer.height),
                    $0.baseAddress,
                    $0.count)
            }
            return image.isValid()
                ? .success(DecodedImage(image: image))
                : .failure(.decodeFailure)
        }
    }

    private enum Limits {
        static let maximumEncodedBytes = 64 * 1024 * 1024
        static let maximumDimension = 32_768
        static let maximumPixels = 64_000_000
        static let maximumDecodedBytes = 256 * 1024 * 1024
    }

    private static func validatedTargetBounds(
        _ source: ImageSource
    ) -> (width: Int32, height: Int32)? {
        validatedDimensions(
            width: Int(source.maxWidth),
            height: Int(source.maxHeight),
            bytesPerPixel: 4)
    }

    private static func targetFailure(
        _ source: ImageSource
    ) -> ImageDecodeFailure {
        source.maxWidth == 0 || source.maxHeight == 0
            ? .invalidDimensions
            : .limitExceeded
    }

    private static func validatedDimensions(
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) -> (width: Int32, height: Int32)? {
        guard width > 0, height > 0,
              width <= Limits.maximumDimension,
              height <= Limits.maximumDimension
        else { return nil }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow,
              pixels.partialValue <= Limits.maximumPixels
        else { return nil }
        let bytes = pixels.partialValue.multipliedReportingOverflow(
            by: bytesPerPixel)
        guard !bytes.overflow,
              bytes.partialValue <= Limits.maximumDecodedBytes
        else { return nil }
        return (Int32(width), Int32(height))
    }

    private static func encodedFileSize(_ path: String) -> Int? {
        guard !path.isEmpty,
              let file = fopen(path, "rb")
        else { return nil }
        defer { fclose(file) }
        guard fseek(file, 0, SEEK_END) == 0 else { return nil }
        let length = ftell(file)
        guard length > 0 else { return nil }
        return Int(exactly: length)
    }

    private static func mapMetadata(
        _ metadata: nucleus.skia.EncodedImageMetadata
    ) -> Result<ImageMetadata, ImageDecodeFailure> {
        guard metadata.isSuccess() else {
            return .failure(mapFailure(metadata.status))
        }
        return .success(ImageMetadata(
            width: metadata.width,
            height: metadata.height,
            isVector: metadata.isVector))
    }

    private static func mapDecode(
        _ decoded: nucleus.skia.RasterDecodeResult
    ) -> Result<DecodedImage, ImageDecodeFailure> {
        guard decoded.isSuccess() else {
            return .failure(mapFailure(decoded.status))
        }
        return .success(DecodedImage(image: decoded.image))
    }

    private static func mapFailure(
        _ status: nucleus.skia.RasterDecodeStatus
    ) -> ImageDecodeFailure {
        switch status {
        case .unreadableInput:
            .unreadableInput
        case .unsupportedFormat:
            .unsupportedFormat
        case .invalidDimensions:
            .invalidDimensions
        case .limitExceeded:
            .limitExceeded
        case .decodeFailure, .success:
            .decodeFailure
        @unknown default:
            .decodeFailure
        }
    }
}
