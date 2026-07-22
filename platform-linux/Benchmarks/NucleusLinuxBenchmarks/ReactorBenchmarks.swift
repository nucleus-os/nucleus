import Dispatch
import Glibc
import NucleusBenchmarkSupport
import NucleusLinuxReactor
import NucleusLinuxReactorC

@MainActor
func reactorWakeCoalescingWorkload(
    wakeCount: Int
) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "linux-reactor",
        name: "cross-thread-wake-coalescing-\(wakeCount)",
        inputSize: UInt64(wakeCount),
        seed: 0x5552_494E_4700_0001,
        budgets: [
            .exact("wake_requests", UInt64(wakeCount)),
            .exact("control_signal_writes", 1),
            .exact("coalesced_wake_requests", UInt64(wakeCount - 1)),
            .exact("control_signal_write_failures", 0),
            .exact("explicit_wake_batches", 1),
            .exact("events_delivered", 0),
        ],
        body: {
            precondition(wakeCount > 0)
            var phases = BenchmarkPhaseRecorder()
            let reactor = try LinuxHostReactor(queueDepth: 32)

            phases.measure("wake_burst") {
                DispatchQueue.concurrentPerform(iterations: wakeCount) { _ in
                    reactor.wake()
                }
            }
            let batch = try await phases.measure("drain") {
                try await reactor.wait(
                    interests: [],
                    timeoutNanoseconds: 1_000_000_000)
            }
            guard batch.wasExplicitlyWoken,
                  !batch.didReachDeadline,
                  batch.events.isEmpty
            else {
                await reactor.shutdown()
                throw BenchmarkFailure.semantic(
                    "reactor wake benchmark did not return the control wake")
            }
            let metrics = reactor.metrics
            let resources = try BenchmarkResourceSnapshot.capture()
            await phases.measure("teardown") {
                await reactor.shutdown()
            }

            var checksum = metrics.explicitWakeRequests
            checksum.mix(metrics.controlSignalWrites)
            checksum.mix(metrics.coalescedControlWakeRequests)
            return BenchmarkSample(
                metrics: [
                    "wake_requests": metrics.explicitWakeRequests,
                    "control_signal_writes": metrics.controlSignalWrites,
                    "coalesced_wake_requests":
                        metrics.coalescedControlWakeRequests,
                    "control_signal_write_failures":
                        metrics.controlSignalWriteFailures,
                    "explicit_wake_batches": batch.wasExplicitlyWoken ? 1 : 0,
                    "events_delivered": UInt64(batch.events.count),
                    "copied_bytes": 0,
                ],
                measurements: observedResourceMeasurements(resources),
                semanticChecksum: checksum,
                phaseNanoseconds: phases.phaseNanoseconds)
        })
}

@MainActor
func reactorReadinessBacklogWorkload(
    descriptorCount: Int,
    completionBudget: Int
) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "linux-reactor",
        name: "readiness-backlog-\(descriptorCount)-budget-\(completionBudget)",
        inputSize: UInt64(descriptorCount),
        seed: 0x5552_494E_4700_0002,
        budgets: [
            .exact("descriptors_registered", UInt64(descriptorCount)),
            .exact("events_delivered", UInt64(descriptorCount)),
            .exact("duplicate_events", 0),
            .exact("oversized_batches", 0),
            .exact("bounded_backlog_observed", 1),
            .exact("polls_prepared", UInt64(descriptorCount + 2)),
            .exact("requests_submitted", UInt64(descriptorCount + 2)),
            .exact("submission_calls", 1),
            .exact("stale_completions", 0),
        ],
        body: {
            precondition(descriptorCount > completionBudget)
            precondition(completionBudget > 0)
            var phases = BenchmarkPhaseRecorder()
            var pipes: [[Int32]] = []
            pipes.reserveCapacity(descriptorCount)
            for _ in 0..<descriptorCount {
                var descriptors = [Int32](repeating: -1, count: 2)
                guard nucleus_linux_reactor_create_pipe(&descriptors) == 0 else {
                    closePipes(pipes)
                    throw BenchmarkFailure.semantic(
                        "failed to create reactor benchmark pipe")
                }
                pipes.append(descriptors)
            }
            defer { closePipes(pipes) }

            let reactor = try LinuxHostReactor(
                queueDepth: UInt32(descriptorCount + 16),
                completionBudget: completionBudget)
            var interests = pipes.enumerated().map { index, descriptors in
                LinuxReactorInterest(
                    token: UInt64(index + 1),
                    fileDescriptor: descriptors[0],
                    events: Int16(POLLIN))
            }

            reactor.wake()
            let primingBatch = try await phases.measure("register") {
                try await reactor.wait(
                    interests: interests,
                    timeoutNanoseconds: 1_000_000_000)
            }
            guard primingBatch.wasExplicitlyWoken else {
                await reactor.shutdown()
                throw BenchmarkFailure.semantic(
                    "reactor registration did not return its control wake")
            }
            try phases.measure("signal") {
                for descriptors in pipes {
                    try signalPipe(descriptors[1])
                }
            }

            var delivered = Set<UInt64>()
            delivered.reserveCapacity(descriptorCount)
            var duplicateEvents: UInt64 = 0
            var oversizedBatches: UInt64 = 0
            var boundedBacklogObserved = false
            try await phases.measure("drain") {
                while delivered.count < descriptorCount {
                    let batch = try await reactor.wait(
                        interests: interests,
                        timeoutNanoseconds: 1_000_000_000)
                    if batch.didReachDeadline {
                        throw BenchmarkFailure.semantic(
                            "reactor readiness benchmark reached its deadline")
                    }
                    if batch.events.count > completionBudget {
                        oversizedBatches += 1
                    }
                    boundedBacklogObserved = boundedBacklogObserved
                        || batch.didExhaustCompletionBudget
                    for event in batch.events {
                        guard event.failureCode == nil,
                              event.returnedEvents & Int16(POLLIN) != 0,
                              event.token > 0,
                              event.token <= UInt64(descriptorCount)
                        else {
                            throw BenchmarkFailure.semantic(
                                "reactor readiness benchmark returned an invalid event")
                        }
                        if delivered.insert(event.token).inserted {
                            try drainPipe(pipes[Int(event.token - 1)][0])
                        } else {
                            duplicateEvents += 1
                        }
                    }
                    interests.removeAll { delivered.contains($0.token) }
                }
            }
            let metrics = reactor.metrics
            let resources = try BenchmarkResourceSnapshot.capture()
            await phases.measure("teardown") {
                await reactor.shutdown()
            }

            var checksum: UInt64 = 0
            for token in delivered.sorted() { checksum.mix(token) }
            return BenchmarkSample(
                metrics: [
                    "descriptors_registered": UInt64(descriptorCount),
                    "events_delivered": UInt64(delivered.count),
                    "duplicate_events": duplicateEvents,
                    "oversized_batches": oversizedBatches,
                    "bounded_backlog_observed": boundedBacklogObserved ? 1 : 0,
                    "polls_prepared": metrics.pollsPrepared,
                    "requests_submitted": metrics.requestsSubmitted,
                    "submission_calls": metrics.submissionCalls,
                    "stale_completions": metrics.staleCompletionsRejected,
                    "copied_bytes": 0,
                ],
                measurements: observedResourceMeasurements(resources),
                semanticChecksum: checksum,
                phaseNanoseconds: phases.phaseNanoseconds)
        })
}

@MainActor
func reactorCancellationChurnWorkload(
    replacementCount: Int
) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "linux-reactor",
        name: "token-replacement-cancellation-\(replacementCount)",
        inputSize: UInt64(replacementCount),
        seed: 0x5552_494E_4700_0003,
        budgets: [
            .exact("token_replacements", UInt64(replacementCount - 1)),
            .exact("polls_prepared", UInt64(replacementCount + 2)),
            .exact("cancellations_prepared", UInt64(replacementCount - 1)),
            .exact("submission_calls", UInt64(replacementCount)),
            .exact("requests_submitted", UInt64(replacementCount * 2 + 1)),
            .exact("wake_requests", UInt64(replacementCount)),
            .exact("control_signal_write_failures", 0),
            .exact("unexpected_events", 0),
        ],
        body: {
            precondition(replacementCount > 1)
            var firstPipe = [Int32](repeating: -1, count: 2)
            var secondPipe = [Int32](repeating: -1, count: 2)
            guard nucleus_linux_reactor_create_pipe(&firstPipe) == 0 else {
                throw BenchmarkFailure.semantic(
                    "failed to create first cancellation benchmark pipe")
            }
            guard nucleus_linux_reactor_create_pipe(&secondPipe) == 0 else {
                closePipes([firstPipe])
                throw BenchmarkFailure.semantic(
                    "failed to create second cancellation benchmark pipe")
            }
            defer { closePipes([firstPipe, secondPipe]) }

            var phases = BenchmarkPhaseRecorder()
            let reactor = try LinuxHostReactor(queueDepth: 32)
            var unexpectedEvents: UInt64 = 0
            try await phases.measure("replace_and_cancel") {
                for index in 0..<replacementCount {
                    let descriptor = index.isMultiple(of: 2)
                        ? firstPipe[0]
                        : secondPipe[0]
                    reactor.wake()
                    let batch = try await reactor.wait(
                        interests: [.init(
                            token: 1,
                            fileDescriptor: descriptor,
                            events: Int16(POLLIN))],
                        timeoutNanoseconds: 1_000_000_000)
                    guard batch.wasExplicitlyWoken,
                          !batch.didReachDeadline
                    else {
                        throw BenchmarkFailure.semantic(
                            "reactor cancellation benchmark missed its control wake")
                    }
                    unexpectedEvents += UInt64(batch.events.count)
                }
            }
            let metrics = reactor.metrics
            let resources = try BenchmarkResourceSnapshot.capture()
            await phases.measure("teardown") {
                await reactor.shutdown()
            }

            var checksum = metrics.pollsPrepared
            checksum.mix(metrics.cancellationsPrepared)
            checksum.mix(metrics.requestsSubmitted)
            return BenchmarkSample(
                metrics: [
                    "token_replacements": UInt64(replacementCount - 1),
                    "polls_prepared": metrics.pollsPrepared,
                    "cancellations_prepared": metrics.cancellationsPrepared,
                    "submission_calls": metrics.submissionCalls,
                    "requests_submitted": metrics.requestsSubmitted,
                    "wake_requests": metrics.explicitWakeRequests,
                    "control_signal_write_failures":
                        metrics.controlSignalWriteFailures,
                    "unexpected_events": unexpectedEvents,
                    "copied_bytes": 0,
                ],
                measurements: observedResourceMeasurements(resources),
                semanticChecksum: checksum,
                phaseNanoseconds: phases.phaseNanoseconds)
        })
}

private func observedResourceMeasurements(
    _ snapshot: BenchmarkResourceSnapshot
) -> [String: Int64] {
    [
        "heap_live_bytes_observed": Int64(clamping: snapshot.heapLiveBytes),
        "allocator_mapped_bytes_observed": Int64(
            clamping: snapshot.allocatorMappedBytes),
        "maximum_resident_bytes_observed": Int64(
            clamping: snapshot.maximumResidentBytes),
        "open_file_descriptors_observed": Int64(
            clamping: snapshot.openFileDescriptors),
    ]
}

private func signalPipe(_ descriptor: Int32) throws {
    var value: UInt8 = 1
    let written = withUnsafeBytes(of: &value) { bytes in
        Glibc.write(descriptor, bytes.baseAddress, bytes.count)
    }
    guard written == MemoryLayout<UInt8>.size else {
        throw BenchmarkFailure.semantic(
            "failed to signal reactor benchmark pipe")
    }
}

private func drainPipe(_ descriptor: Int32) throws {
    var value: UInt8 = 0
    let readCount = withUnsafeMutableBytes(of: &value) { bytes in
        Glibc.read(descriptor, bytes.baseAddress, bytes.count)
    }
    guard readCount == MemoryLayout<UInt8>.size else {
        throw BenchmarkFailure.semantic(
            "failed to drain reactor benchmark pipe")
    }
}

private func closePipes(_ pipes: [[Int32]]) {
    for descriptor in pipes.joined() where descriptor >= 0 {
        _ = Glibc.close(descriptor)
    }
}
