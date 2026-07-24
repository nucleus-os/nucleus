import Dispatch
import Foundation
import Glibc
import NucleusAndroidDrmC
import NucleusAndroidDrmCTestSupport
import NucleusAndroidGfxstreamTransport
import Synchronization

private final class SendableLifetimeDomain: @unchecked Sendable {
    let handle: OpaquePointer

    init?() {
        guard let handle = nucleus_android_test_gpu_lifetime_domain_create() else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        nucleus_android_test_gpu_lifetime_domain_destroy(handle)
    }

    var diagnostic: nucleus_android_gpu_diagnostic? {
        var diagnostic = nucleus_android_gpu_diagnostic()
        guard nucleus_android_gpu_get_diagnostic(handle, &diagnostic) == 0 else {
            return nil
        }
        return diagnostic
    }
}

private final class SendableLifetimeBuffer: @unchecked Sendable {
    let domain: SendableLifetimeDomain
    private var handle: OpaquePointer?

    init?(domain: SendableLifetimeDomain) {
        guard let handle =
            nucleus_android_test_gpu_buffer_lifetime_domain_create(domain.handle)
        else {
            return nil
        }
        self.domain = domain
        self.handle = handle
    }

    deinit {
        release()
    }

    func recordSubmission() -> UInt64 {
        guard let handle else { return 0 }
        return nucleus_android_test_gpu_buffer_record_submission(handle)
    }

    func release() {
        guard let handle else { return }
        self.handle = nil
        nucleus_android_gpu_buffer_destroy(handle)
    }
}

@main
enum NucleusAndroidThreadSanitizerHarness {
    private static func runSharedRingStress() -> Bool {
        let producerCount = 4
        let packetsPerProducer = 512
        let expectedCount = producerCount * packetsPerProducer
        let mapping: SharedCommandRingMapping
        let producer: SharedCommandProducer
        let consumer: SharedCommandConsumer
        do {
            mapping = try SharedCommandRingMapping(
                slotCount: 32,
                slotSize: 64)
            producer = try mapping.makeProducer()
            consumer = try mapping.makeConsumer()
        } catch {
            return false
        }

        let failures = Mutex(0)
        let seen = Mutex(Set<UInt64>())
        let group = DispatchGroup()
        let queue = DispatchQueue.global()
        group.enter()
        queue.async {
            defer { group.leave() }
            while seen.withLock({ $0.count }) < expectedCount,
                  failures.withLock({ $0 }) == 0
            {
                do {
                    let packet = try consumer.read()
                    guard packet.count == MemoryLayout<UInt64>.size else {
                        failures.withLock { $0 += 1 }
                        return
                    }
                    let value = packet.withUnsafeBytes {
                        $0.loadUnaligned(as: UInt64.self)
                    }
                    _ = seen.withLock { $0.insert(value) }
                } catch GfxstreamTransportError.empty {
                    _ = sched_yield()
                } catch {
                    failures.withLock { $0 += 1 }
                    return
                }
            }
        }
        for producerID in 0..<producerCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                for sequence in 0..<packetsPerProducer {
                    var value =
                        UInt64(producerID * packetsPerProducer + sequence)
                    let packet = withUnsafeBytes(of: &value) {
                        Data($0)
                    }
                    while failures.withLock({ $0 }) == 0 {
                        do {
                            try producer.write(packet)
                            break
                        } catch GfxstreamTransportError.full {
                            _ = sched_yield()
                        } catch {
                            failures.withLock { $0 += 1 }
                            return
                        }
                    }
                }
            }
        }
        group.wait()
        guard failures.withLock({ $0 }) == 0,
              seen.withLock({ $0.count }) == expectedCount,
              seen.withLock({ $0 }) ==
                Set(0..<UInt64(expectedCount)),
              let diagnostic = try? producer.diagnostic,
              diagnostic.maximumOccupancy <= producer.slotCount
        else {
            return false
        }
        return true
    }

    static func main() {
        guard let domain = SendableLifetimeDomain() else { exit(1) }
        let bufferCount = 4_096
        let buffers = (0..<bufferCount).compactMap { _ in
            SendableLifetimeBuffer(domain: domain)
        }
        guard buffers.count == bufferCount else { exit(2) }

        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: bufferCount) { index in
            if buffers[index].recordSubmission() == 0 {
                failures.withLock { $0 += 1 }
            }
            buffers[index].release()
        }

        guard failures.withLock({ $0 }) == 0,
              let retired = domain.diagnostic,
              retired.live_buffer_count == UInt64(bufferCount),
              retired.retired_buffer_count == UInt64(bufferCount),
              retired.reclaimed_buffer_count == 0,
              retired.submitted_serial == UInt64(bufferCount),
              retired.completed_serial == 0
        else {
            exit(3)
        }

        nucleus_android_test_gpu_complete_through(
            domain.handle,
            retired.submitted_serial)
        guard let reclaimed = domain.diagnostic,
              reclaimed.live_buffer_count == 0,
              reclaimed.retired_buffer_count == 0,
              reclaimed.reclaimed_buffer_count == UInt64(bufferCount),
              reclaimed.completed_serial == reclaimed.submitted_serial
        else {
            exit(4)
        }
        guard runSharedRingStress() else {
            exit(5)
        }
        exit(0)
    }
}
