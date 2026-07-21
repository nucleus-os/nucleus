import Dispatch
import Glibc
import NucleusRenderModel
import NucleusRenderer
import Synchronization

private final class WakeCounter: AsyncRenderWakeSink, Sendable {
    private let count = Mutex(0)

    nonisolated func signalRenderWork() {
        count.withLock { $0 += 1 }
    }

    var value: Int { count.withLock { $0 } }
}

private struct SendableQueue: @unchecked Sendable {
    let value: ImageDecodeQueue
}

@main
enum NucleusCoreThreadSanitizerHarness {
    static func main() {
        let mutexControl = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 1_024) { _ in
            mutexControl.withLock { $0 += 1 }
        }
        guard mutexControl.withLock({ $0 }) == 1_024 else {
            exit(1)
        }
        guard exerciseRegistries() else {
            exit(4)
        }

        let wakeCounter = WakeCounter()
        let queue = ImageDecodeQueue(
            wakeSink: wakeCounter,
            workerCount: 2)
        let sendableQueue = SendableQueue(value: queue)
        let requestCount = 256
        let cancelledDivisor = 4
        let pixels = [UInt8](
            repeating: 0x80,
            count: 32 * 32 * 4)

        DispatchQueue.concurrentPerform(iterations: requestCount) { index in
            let handle = UInt64(index + 1)
            let source = ImageSource(content: .raw(RawPixelBuffer(
                width: 32,
                height: 32,
                order: .rgba,
                pixels: pixels)))
            guard sendableQueue.value.submit(
                handle: handle,
                source: source)
            else {
                return
            }
            if index.isMultiple(of: cancelledDivisor) {
                sendableQueue.value.cancel(handle: handle)
            }
        }

        let expected = requestCount - requestCount / cancelledDivisor
        var completed: Set<UInt64> = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while completed.count < expected, ContinuousClock.now < deadline {
            for result in queue.drain() {
                guard result.isValid,
                      result.width == 32,
                      result.height == 32
                else {
                    queue.shutdown()
                    exit(2)
                }
                completed.insert(result.handle)
            }
            usleep(1_000)
        }
        queue.shutdown()

        guard completed.count == expected,
              wakeCounter.value > 0,
              !queue.hasWorkers
        else {
            exit(3)
        }
        exit(0)
    }

    private static func exerciseRegistries() -> Bool {
        let iterations = 1_024

        let images = ImageStore()
        let imageSource = ImageSource(
            path: "/nucleus/tsan/image",
            maxWidth: 64,
            maxHeight: 64)
        let imageHandle = images.register(imageSource)
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let handle = images.register(imageSource)
            images.retain(handle)
            images.release(handle)
            _ = images.source(handle)
        }
        DispatchQueue.concurrentPerform(iterations: iterations + 1) { _ in
            images.release(imageHandle)
        }
        guard images.count == 0,
              images.takeEvictedHandles() == [imageHandle]
        else { return false }

        let effects = RuntimeEffectStore()
        let effectSource = RuntimeEffectSource(
            sksl: "half4 main() { return half4(1); }")
        let effectHandle = effects.register(effectSource)
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let handle = effects.register(effectSource)
            effects.retain(handle)
            effects.release(handle)
            _ = effects.source(handle)
        }
        DispatchQueue.concurrentPerform(iterations: iterations + 1) { _ in
            effects.release(effectHandle)
        }
        guard effects.count == 0,
              effects.takeEvictedHandles() == [effectHandle]
        else { return false }

        let snapshots = SnapshotService()
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let handle = snapshots.registerTextureHandle(
                TextureHandle(raw: UInt64(index + 1)),
                size: Bounds(w: 32, h: 32))
            snapshots.retain(handle)
            _ = snapshots.resolve(handle)
            _ = snapshots.release(handle)
            _ = snapshots.release(handle)
        }
        guard snapshots.liveCount == 0 else { return false }

        let paint = PaintContentStore()
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let handle = paint.register([], width: 32, height: 32)
            paint.retain(handle)
            _ = paint.content(handle)
            paint.release(handle)
            paint.release(handle)
        }
        guard paint.count == 0 else { return false }

        let host = SwiftResourceHost()
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            if index.isMultiple(of: 2) {
                host.invalidate()
            } else {
                _ = host.accepts(rawIdentity: host.identity.rawValue)
            }
            _ = SwiftResourceHost()
        }
        return !host.isLive
    }
}
