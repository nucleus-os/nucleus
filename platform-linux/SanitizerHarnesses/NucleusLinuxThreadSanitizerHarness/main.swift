import Dispatch
import Glibc
import NucleusLinuxReactor
import NucleusLinuxReactorC

@main
enum NucleusLinuxThreadSanitizerHarness {
    @MainActor
    static func main() async {
        do {
            let reactor = try LinuxHostReactor(queueDepth: 16)

            for _ in 0..<256 {
                DispatchQueue.global().async {
                    reactor.wake()
                }
                let batch = try await reactor.wait(
                    interests: [],
                    timeoutNanoseconds: 1_000_000_000)
                guard batch.wasExplicitlyWoken else { exit(4) }
            }

            let waitMetrics = reactor.metrics
            guard waitMetrics.waitCalls == 256,
                  waitMetrics.batchesReturned == 256,
                  waitMetrics.completionSourceWakeups > 0,
                  waitMetrics.controlSignalWriteFailures == 0
            else { exit(5) }

            let group = DispatchGroup()
            for _ in 0..<8 {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<4_096 {
                        reactor.wake()
                    }
                    group.leave()
                }
            }

            reactor.shutdown()
            group.wait()

            var replacements: [Int32] = []
            for _ in 0..<8 {
                let descriptor = nucleus_linux_reactor_create_event_fd()
                guard descriptor >= 0 else { exit(2) }
                replacements.append(descriptor)
            }
            defer {
                for descriptor in replacements {
                    _ = Glibc.close(descriptor)
                }
            }

            DispatchQueue.concurrentPerform(iterations: 4_096) { _ in
                reactor.wake()
            }
            guard replacements.allSatisfy({
                nucleus_linux_reactor_drain_counter($0) == 0
            }) else {
                exit(3)
            }
            exit(0)
        } catch {
            exit(1)
        }
    }
}
