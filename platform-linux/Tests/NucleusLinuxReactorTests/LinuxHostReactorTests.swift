import Glibc
import Foundation
import NucleusLinuxReactor
import NucleusLinuxReactorC
import Testing

@Suite(.serialized)
@MainActor
struct LinuxHostReactorTests {
    @Test
    func waitingSuspendsTheMainActor() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)
        var taskRan = false

        Task { @MainActor in
            taskRan = true
            reactor.wake()
        }

        let batch = try await reactor.wait(
            interests: [],
            timeoutNanoseconds: 1_000_000_000)
        #expect(taskRan)
        #expect(batch.wasExplicitlyWoken)
        #expect(!batch.didReachDeadline)
        #expect(batch.executorResumeLatencyNanoseconds != nil)
        let metrics = reactor.metrics
        #expect(metrics.waitCalls == 1)
        #expect(metrics.batchesReturned == 1)
        #expect(metrics.pollsPrepared == 2)
        #expect(metrics.submissionCalls == 1)
        #expect(metrics.requestsSubmitted == 2)
        #expect(metrics.completionsConsumed >= 1)
        #expect(metrics.completionSourceWakeups >= 1)
        #expect(metrics.controlSignalWriteFailures == 0)
        await reactor.shutdown()
    }

    @Test
    func explicitWakeBurstsCoalesceBeforeEnteringTheKernel() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)

        for _ in 0..<32 {
            reactor.wake()
        }
        let batch = try await reactor.wait(
            interests: [],
            timeoutNanoseconds: 1_000_000_000)

        #expect(batch.wasExplicitlyWoken)
        let metrics = reactor.metrics
        #expect(metrics.explicitWakeRequests == 32)
        #expect(metrics.controlSignalWrites == 1)
        #expect(metrics.coalescedControlWakeRequests == 31)
        #expect(metrics.controlSignalWriteFailures == 0)
        await reactor.shutdown()
    }

    @Test
    func readinessCarriesThePollMaskAndRearms() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(nucleus_linux_reactor_create_pipe(&descriptors) == 0)
        let descriptor = descriptors[0]
        defer {
            _ = Glibc.close(descriptors[0])
            _ = Glibc.close(descriptors[1])
        }
        let interest = LinuxReactorInterest(
            token: 42,
            fileDescriptor: descriptor,
            events: Int16(POLLIN))

        signal(descriptors[1])
        var batch = try await reactor.wait(
            interests: [interest],
            timeoutNanoseconds: 1_000_000_000)
        #expect(batch.events == [LinuxReactorEvent(
            token: 42,
            result: Int32(POLLIN))])
        drain(descriptor)

        signal(descriptors[1])
        batch = try await reactor.wait(
            interests: [interest],
            timeoutNanoseconds: 1_000_000_000)
        #expect(batch.events.first?.token == 42)
        #expect(batch.events.first.map {
            $0.returnedEvents & Int16(POLLIN) != 0
        } == true)
        await reactor.shutdown()
    }

    @Test
    func finiteDeadlineDoesNotNeedAnotherDescriptor() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)
        let batch = try await reactor.wait(
            interests: [],
            timeoutNanoseconds: 1_000_000)
        #expect(batch.didReachDeadline)
        #expect(batch.events.isEmpty)
        await reactor.shutdown()
    }

    @Test
    func invalidRequestedPollBitsAreRejected() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(nucleus_linux_reactor_create_pipe(&descriptors) == 0)
        defer {
            for descriptor in descriptors { _ = Glibc.close(descriptor) }
        }

        do {
            _ = try await reactor.wait(
                interests: [.init(
                    token: 52,
                    fileDescriptor: descriptors[0],
                    events: Int16(POLLERR))],
                timeoutNanoseconds: nil)
            Issue.record("reactor accepted a result-only poll bit")
        } catch let error {
            #expect(error == .invalidInterest(
                token: 52,
                fileDescriptor: descriptors[0],
                events: Int16(POLLERR)))
        }
        await reactor.shutdown()
    }

    @Test
    func multishotPollSurvivesSeparateReadinessTransitions() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(nucleus_linux_reactor_create_pipe(&descriptors) == 0)
        defer {
            for descriptor in descriptors { _ = Glibc.close(descriptor) }
        }
        let interest = LinuxReactorInterest(
            token: 51,
            fileDescriptor: descriptors[0],
            events: Int16(POLLIN),
            mode: .multishot)

        for _ in 0..<2 {
            signal(descriptors[1])
            let batch = try await reactor.wait(
                interests: [interest],
                timeoutNanoseconds: 1_000_000_000)
            #expect(batch.events.contains { event in
                event.token == 51
                    && event.returnedEvents & Int16(POLLIN) != 0
            })
            drain(descriptors[0])
        }
        await reactor.shutdown()
    }

    @Test
    func completionBudgetReturnsControlBetweenReadinessBursts() async throws {
        let reactor = try LinuxHostReactor(
            queueDepth: 16,
            completionBudget: 1)
        var pipes = [[Int32]]()
        for _ in 0..<3 {
            var descriptors = [Int32](repeating: -1, count: 2)
            #expect(nucleus_linux_reactor_create_pipe(&descriptors) == 0)
            pipes.append(descriptors)
        }
        defer {
            for descriptor in pipes.flatMap({ $0 }) {
                _ = Glibc.close(descriptor)
            }
        }
        var interests = pipes.enumerated().map { index, descriptors in
            LinuxReactorInterest(
                token: UInt64(100 + index),
                fileDescriptor: descriptors[0],
                events: Int16(POLLIN))
        }

        reactor.wake()
        _ = try await reactor.wait(
            interests: interests,
            timeoutNanoseconds: nil)
        for descriptors in pipes { signal(descriptors[1]) }

        var delivered = Set<UInt64>()
        var observedBoundedBacklog = false
        while delivered.count < pipes.count {
            let batch = try await reactor.wait(
                interests: interests,
                timeoutNanoseconds: 1_000_000_000)
            #expect(batch.events.count <= 1)
            observedBoundedBacklog = observedBoundedBacklog
                || batch.didExhaustCompletionBudget
            for event in batch.events where delivered.insert(event.token).inserted {
                drain(pipes[Int(event.token - 100)][0])
            }
            interests.removeAll { delivered.contains($0.token) }
        }
        #expect(delivered == Set([100, 101, 102]))
        #expect(observedBoundedBacklog)
        #expect(reactor.metrics.completionBudgetExhaustions >= 1)
        #expect(reactor.metrics.pollsPrepared == 5)
        await reactor.shutdown()
    }

    @Test
    func replacingATokenRejectsTheCancelledDescriptorsCompletion() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)
        var firstPipe = [Int32](repeating: -1, count: 2)
        var secondPipe = [Int32](repeating: -1, count: 2)
        #expect(nucleus_linux_reactor_create_pipe(&firstPipe) == 0)
        #expect(nucleus_linux_reactor_create_pipe(&secondPipe) == 0)
        let first = firstPipe[0]
        let second = secondPipe[0]
        defer {
            for descriptor in firstPipe + secondPipe {
                _ = Glibc.close(descriptor)
            }
        }

        reactor.wake()
        _ = try await reactor.wait(
            interests: [.init(
                token: 7,
                fileDescriptor: first,
                events: Int16(POLLIN))],
            timeoutNanoseconds: nil)

        signal(secondPipe[1])
        let batch = try await reactor.wait(
            interests: [.init(
                token: 7,
                fileDescriptor: second,
                events: Int16(POLLIN))],
            timeoutNanoseconds: 1_000_000_000)
        #expect(batch.events.count == 1)
        #expect(batch.events[0].token == 7)
        #expect(batch.events[0].failureCode == nil)
        await reactor.shutdown()
    }

    @Test
    func removingAnInterestCancelsItsOutstandingPoll() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(nucleus_linux_reactor_create_pipe(&descriptors) == 0)
        defer {
            for descriptor in descriptors { _ = Glibc.close(descriptor) }
        }

        reactor.wake()
        _ = try await reactor.wait(
            interests: [.init(
                token: 19,
                fileDescriptor: descriptors[0],
                events: Int16(POLLIN))],
            timeoutNanoseconds: nil)

        signal(descriptors[1])
        let batch = try await reactor.wait(
            interests: [],
            timeoutNanoseconds: 1_000_000)
        #expect(batch.didReachDeadline)
        #expect(batch.events.isEmpty)
        await reactor.shutdown()
    }

    @Test
    func shutdownResumesAnOutstandingWait() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)
        let waiter = Task { @MainActor in
            try await reactor.wait(
                interests: [],
                timeoutNanoseconds: nil)
        }
        await Task.yield()
        await reactor.shutdown()

        do {
            _ = try await waiter.value
            Issue.record("stopped reactor unexpectedly produced a batch")
        } catch let error as LinuxHostReactorError {
            #expect(error == .stopped)
        } catch {
            Issue.record("unexpected reactor error: \(error)")
        }
    }

    @Test
    func wakeAfterShutdownCannotSignalAReusedDescriptor() async throws {
        let reactor = try LinuxHostReactor(queueDepth: 16)
        await reactor.shutdown()

        var replacements: [Int32] = []
        for _ in 0..<4 {
            let descriptor = nucleus_linux_reactor_create_event_fd()
            #expect(descriptor >= 0)
            replacements.append(descriptor)
        }
        defer {
            for descriptor in replacements { _ = Glibc.close(descriptor) }
        }

        reactor.wake()
        for descriptor in replacements {
            #expect(nucleus_linux_reactor_drain_counter(descriptor) == 0)
        }
    }

    @Test
    func repeatedShutdownReturnsKernelResourcesToBaseline() async throws {
        let warmup = try LinuxHostReactor(queueDepth: 16)
        warmup.wake()
        _ = try await warmup.wait(
            interests: [],
            timeoutNanoseconds: 1_000_000_000)
        await warmup.shutdown()

        let baselineDescriptors = try processEntryCount(at: "/proc/self/fd")
        let baselineTasks = try processEntryCount(at: "/proc/self/task")

        for _ in 0..<32 {
            let reactor = try LinuxHostReactor(queueDepth: 16)
            reactor.wake()
            _ = try await reactor.wait(
                interests: [],
                timeoutNanoseconds: 1_000_000_000)
            await reactor.shutdown()
            #expect(try processEntryCount(at: "/proc/self/fd")
                == baselineDescriptors)
        }

        #expect(try processEntryCount(at: "/proc/self/task")
            <= baselineTasks + 1)
    }

    private func signal(_ descriptor: Int32) {
        var value: UInt8 = 1
        let count = withUnsafeBytes(of: &value) {
            Glibc.write(descriptor, $0.baseAddress, $0.count)
        }
        #expect(count == MemoryLayout<UInt8>.size)
    }

    private func drain(_ descriptor: Int32) {
        var value: UInt8 = 0
        let count = withUnsafeMutableBytes(of: &value) {
            Glibc.read(descriptor, $0.baseAddress, $0.count)
        }
        #expect(count == MemoryLayout<UInt8>.size)
    }

    private func processEntryCount(at path: String) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: path).count
    }
}
