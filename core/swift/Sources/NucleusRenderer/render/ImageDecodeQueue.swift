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

/// A decoded image on its way back to the render thread.
///
/// Carries the Skia image itself rather than a pixel array. A raster `SkImage` is
/// immutable once made and its refcount is atomic, so handing one between threads
/// is sound — and the alternative costs two full-resolution copies of every
/// wallpaper, one to read the pixels out and one to build the image again.
package struct DecodedImageResult: @unchecked Sendable {
    package var handle: UInt64
    package var image: nucleus.skia.RasterImage

    // Plain-typed accessors. The C++ `Image` type does not resolve through a
    // `@testable` import, so anything that wants to assert about a result
    // without being the renderer needs these.
    package var isValid: Bool { image.isValid() }
    package var width: Int32 { image.width() }
    package var height: Int32 { image.height() }
}

/// Decodes images off the render thread.
///
/// This is the first background thread in the render core, and it is deliberately
/// a bare one: a worker, a lock, and a condition variable. The work is a single
/// long CPU job per item with no ordering between items, which is the shape that
/// needs a queue rather than a scheduler.
///
/// **Decode happens here; upload does not.** `TextureRegistry` and the driver's
/// decoded-image cache are unsynchronized and owned by the render thread, so the
/// worker only ever produces an immutable image and hands it back. The render
/// thread drains completions at the top of a frame.
package final class ImageDecodeQueue {
    /// State retained by workers. It deliberately has no reference back to the
    /// queue: dropping the queue must be able to start shutdown and join them.
    private final class WorkerState: @unchecked Sendable {
        private struct Request {
            var handle: UInt64
            var generation: UInt64
            var source: ImageSource
        }

        private struct Completion {
            var generation: UInt64
            var result: DecodedImageResult
        }

        private var pending: [Request] = []
        private var pendingHead = 0
        private var completed: [Completion] = []
        /// The generation currently owned by each submitted handle. Generations
        /// distinguish an old in-flight decode from an immediate resubmission of
        /// the same handle after cancellation.
        private var known: [UInt64: UInt64] = [:]
        private var nextGeneration: UInt64 = 1
        private var running = true
        private var latestCompletionToFrameDemandNs: UInt64?

        private let synchronization = BlockingSynchronization()
        private let wakeSink: any AsyncRenderWakeSink
        private let clock = ContinuousClock()

        init(wakeSink: any AsyncRenderWakeSink) {
            self.wakeSink = wakeSink
        }

        func submit(handle: UInt64, source: ImageSource) -> Bool {
            synchronization.withLock {
                guard running, known[handle] == nil else { return false }
                let generation = nextGeneration
                nextGeneration &+= 1
                if nextGeneration == 0 { nextGeneration = 1 }
                known[handle] = generation
                pending.append(Request(
                    handle: handle,
                    generation: generation,
                    source: source))
                synchronization.signal()
                return true
            }
        }

        func drain() -> [DecodedImageResult] {
            synchronization.withLock {
                guard !completed.isEmpty else { return [] }
                let results = completed.map(\.result)
                for completion in completed
                where known[completion.result.handle] == completion.generation {
                    known[completion.result.handle] = nil
                }
                completed.removeAll(keepingCapacity: true)
                return results
            }
        }

        func cancel(handle: UInt64) {
            synchronization.withLock {
                if pendingHead < pending.count {
                    pending = pending[pendingHead...].filter {
                        $0.handle != handle
                    }
                    pendingHead = 0
                } else {
                    pending.removeAll(keepingCapacity: true)
                    pendingHead = 0
                }
                completed.removeAll { $0.result.handle == handle }
                known[handle] = nil
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
                compactPendingIfNeeded()
                synchronization.unlock()

                let image = ImageDecodeQueue.decode(request.source)

                let completionInstant: ContinuousClock.Instant? =
                    synchronization.withLock {
                        if running,
                           known[request.handle] == request.generation,
                           image.isValid()
                        {
                            // One wake covers every result waiting in this
                            // completion burst. Draining empties the burst and
                            // permits the next wake.
                            let completionInstant = completed.isEmpty
                                ? clock.now
                                : nil
                            completed.append(Completion(
                                generation: request.generation,
                                result: DecodedImageResult(
                                    handle: request.handle,
                                    image: image)))
                            return completionInstant
                        }
                        if known[request.handle] == request.generation {
                            known[request.handle] = nil
                        }
                        return nil
                    }

                if let completionInstant {
                    wakeSink.signalRenderWork()
                    let latency = elapsedNanoseconds(
                        completionInstant,
                        clock.now)
                    synchronization.withLock {
                        latestCompletionToFrameDemandNs = latency
                    }
                    Trace.plot(
                        "swift.renderer.image_decode.completion_to_frame_demand_ns",
                        latency)
                }
            }
        }

        private func compactPendingIfNeeded() {
            guard pendingHead >= 64, pendingHead * 2 >= pending.count else { return }
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
    }

    private var state: WorkerState?
    private var workers: [pthread_t] = []

    /// - Parameter workerCount: one is enough for a shell. Decodes are rare,
    ///   bursty, and individually short; more threads would mostly contend.
    ///   Zero explicitly selects the same inline fallback used when every
    ///   requested worker fails to start.
    package init(
        wakeSink: any AsyncRenderWakeSink,
        workerCount: Int = 1
    ) {
        let state = WorkerState(wakeSink: wakeSink)
        self.state = state
        for _ in 0..<max(0, workerCount) {
            let retainedState = Unmanaged.passRetained(state).toOpaque()
            var thread = pthread_t()
            let created = pthread_create(&thread, nil, { pointer in
                let state = Unmanaged<WorkerState>.fromOpaque(pointer!).takeRetainedValue()
                state.workerLoop()
                return nil
            }, retainedState)
            if created == 0 {
                workers.append(thread)
            } else {
                // Failing to spawn is not fatal: `submit` reports that nothing is
                // pending and the caller decodes inline, which is exactly the
                // behaviour that existed before this queue.
                Unmanaged<WorkerState>.fromOpaque(retainedState).release()
            }
        }
    }

    deinit {
        shutdown()
    }

    /// Whether any worker is running. With none, callers must decode inline.
    package var hasWorkers: Bool { !workers.isEmpty }

    /// Latest measured interval from making a completion drainable through
    /// invoking the host's frame-demand sink.
    package var completionToFrameDemandNanoseconds: UInt64? {
        state?.completionToFrameDemandNanoseconds()
    }

    /// Queue a decode. Returns false if this handle is already queued or done,
    /// so a caller can tell "waiting" from "just asked".
    @discardableResult
    package func submit(handle: UInt64, source: ImageSource) -> Bool {
        guard hasWorkers, let state else { return false }
        return state.submit(handle: handle, source: source)
    }

    /// Take everything decoded since the last call.
    package func drain() -> [DecodedImageResult] {
        state?.drain() ?? []
    }

    /// Forget a handle whose source was evicted.
    ///
    /// A decode already running cannot be stopped, so its result is dropped on
    /// arrival instead. Dropping matters more than stopping: the handle may be
    /// re-registered, and delivering a stale image to a reused handle would draw
    /// the wrong picture.
    package func cancel(handle: UInt64) {
        state?.cancel(handle: handle)
    }

    /// Stop the workers and wait for them. Idempotent.
    package func shutdown() {
        guard let state, state.stop() else { return }
        for thread in workers { pthread_join(thread, nil) }
        workers.removeAll()
        // Joining releases the workers' retained state references. Dropping the
        // queue's final reference destroys the C-owned condition and mutex before
        // shutdown returns.
        self.state = nil
    }

    /// The decode itself — the same work the render thread used to do inline.
    static func decode(_ source: ImageSource) -> nucleus.skia.RasterImage {
        let maxWidth = Int32(clamping: source.maxWidth)
        let maxHeight = Int32(clamping: source.maxHeight)

        switch source.content {
        case .file(let path):
            return nucleus.skia.makeEncodedImageFromFile(path, maxWidth, maxHeight)
        case .encoded(let bytes):
            return bytes.withUnsafeBufferPointer {
                nucleus.skia.makeEncodedImageFromMemory(
                    $0.baseAddress, $0.count, maxWidth, maxHeight)
            }
        case .raw(let buffer):
            // An inconsistent buffer decodes to nothing. Producing an image of
            // zero size says that in the vocabulary the caller already checks.
            guard let rgba = buffer.normalizedRGBA() else {
                return nucleus.skia.makeRasterImageRGBA(0, 0, nil, 0)
            }
            return rgba.withUnsafeBufferPointer {
                nucleus.skia.makeRasterImageRGBA(
                    Int32(buffer.width), Int32(buffer.height), $0.baseAddress, $0.count)
            }
        }
    }
}
