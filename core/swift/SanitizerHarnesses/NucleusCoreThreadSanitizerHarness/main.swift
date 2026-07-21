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
}
