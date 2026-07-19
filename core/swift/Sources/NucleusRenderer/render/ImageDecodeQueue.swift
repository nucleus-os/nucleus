#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import NucleusRenderModel
import NucleusSkiaGraphiteBridge

/// A decoded image on its way back to the render thread.
///
/// Carries the Skia image itself rather than a pixel array. A raster `SkImage` is
/// immutable once made and its refcount is atomic, so handing one between threads
/// is sound — and the alternative costs two full-resolution copies of every
/// wallpaper, one to read the pixels out and one to build the image again.
struct DecodedImageResult: @unchecked Sendable {
    var handle: UInt64
    var image: nucleus.skia.Image

    // Plain-typed accessors. The C++ `Image` type does not resolve through a
    // `@testable` import, so anything that wants to assert about a result
    // without being the renderer needs these.
    var isValid: Bool { image.isValid() }
    var width: Int32 { image.width() }
    var height: Int32 { image.height() }
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
final class ImageDecodeQueue: @unchecked Sendable {
    /// Called from a worker when a decode finishes.
    ///
    /// A frame is not otherwise scheduled — nothing in the scene changed, the
    /// image simply arrived — so without this the decode would sit in the queue
    /// until something unrelated caused a repaint.
    var onCompletion: (@Sendable () -> Void)?

    private struct Request {
        var handle: UInt64
        var source: ImageSource
    }

    private var pending: [Request] = []
    private var completed: [DecodedImageResult] = []
    /// Handles submitted and not yet drained. Prevents re-submitting the same
    /// image on every frame it is missing from the cache — which, since a
    /// pending decode draws nothing, is every frame until it lands.
    private var known: Set<UInt64> = []
    private var cancelled: Set<UInt64> = []
    private var running = true

    private var mutex = pthread_mutex_t()
    private var condition = pthread_cond_t()
    private var workers: [pthread_t] = []

    /// - Parameter workerCount: one is enough for a shell. Decodes are rare,
    ///   bursty, and individually short; more threads would mostly contend.
    init(workerCount: Int = 1) {
        pthread_mutex_init(&mutex, nil)
        pthread_cond_init(&condition, nil)

        for _ in 0..<max(1, workerCount) {
            let box = Unmanaged.passRetained(WorkerBox(queue: self)).toOpaque()
            var thread = pthread_t()
            let created = pthread_create(&thread, nil, { pointer in
                let box = Unmanaged<WorkerBox>.fromOpaque(pointer!).takeRetainedValue()
                box.queue.workerLoop()
                return nil
            }, box)
            if created == 0 {
                workers.append(thread)
            } else {
                // Failing to spawn is not fatal: `submit` reports that nothing is
                // pending and the caller decodes inline, which is exactly the
                // behaviour that existed before this queue.
                Unmanaged<WorkerBox>.fromOpaque(box).release()
            }
        }
    }

    deinit {
        shutdown()
        pthread_cond_destroy(&condition)
        pthread_mutex_destroy(&mutex)
    }

    private final class WorkerBox {
        let queue: ImageDecodeQueue
        init(queue: ImageDecodeQueue) { self.queue = queue }
    }

    /// Whether any worker is running. With none, callers must decode inline.
    var hasWorkers: Bool { !workers.isEmpty }

    private func lock() { pthread_mutex_lock(&mutex) }
    private func unlock() { pthread_mutex_unlock(&mutex) }

    /// Queue a decode. Returns false if this handle is already queued or done,
    /// so a caller can tell "waiting" from "just asked".
    @discardableResult
    func submit(handle: UInt64, source: ImageSource) -> Bool {
        guard hasWorkers else { return false }
        lock()
        defer { unlock() }
        guard !known.contains(handle) else { return false }
        known.insert(handle)
        cancelled.remove(handle)
        pending.append(Request(handle: handle, source: source))
        pthread_cond_signal(&condition)
        return true
    }

    /// Take everything decoded since the last call.
    func drain() -> [DecodedImageResult] {
        lock()
        defer { unlock() }
        guard !completed.isEmpty else { return [] }
        let results = completed.filter { !cancelled.contains($0.handle) }
        for result in completed { known.remove(result.handle) }
        cancelled.subtract(completed.map(\.handle))
        completed.removeAll(keepingCapacity: true)
        return results
    }

    /// Forget a handle whose source was evicted.
    ///
    /// A decode already running cannot be stopped, so its result is dropped on
    /// arrival instead. Dropping matters more than stopping: the handle may be
    /// re-registered, and delivering a stale image to a reused handle would draw
    /// the wrong picture.
    func cancel(handle: UInt64) {
        lock()
        defer { unlock() }
        pending.removeAll { $0.handle == handle }
        completed.removeAll { $0.handle == handle }
        if known.contains(handle) { cancelled.insert(handle) }
        known.remove(handle)
    }

    /// Stop the workers and wait for them. Idempotent.
    func shutdown() {
        lock()
        guard running else { unlock(); return }
        running = false
        pending.removeAll()
        pthread_cond_broadcast(&condition)
        unlock()

        for thread in workers { pthread_join(thread, nil) }
        workers.removeAll()
    }

    private func workerLoop() {
        while true {
            lock()
            while running && pending.isEmpty {
                pthread_cond_wait(&condition, &mutex)
            }
            guard running else { unlock(); return }
            let request = pending.removeFirst()
            unlock()

            let image = ImageDecodeQueue.decode(request.source)

            lock()
            // Still wanted? A cancel between submit and here means the handle's
            // source is gone.
            if running && !cancelled.contains(request.handle) && image.isValid() {
                completed.append(
                    DecodedImageResult(handle: request.handle, image: image))
            } else {
                known.remove(request.handle)
                cancelled.remove(request.handle)
            }
            let shouldNotify = running
            unlock()

            if shouldNotify { onCompletion?() }
        }
    }

    /// The decode itself — the same work the render thread used to do inline.
    static func decode(_ source: ImageSource) -> nucleus.skia.Image {
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
