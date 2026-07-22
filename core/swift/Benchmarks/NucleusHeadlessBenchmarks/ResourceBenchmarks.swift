import Observation
import NucleusBenchmarkSupport
import NucleusUI

@MainActor
func resourceBenchmarks() -> [BenchmarkWorkload] {
    [
        imagePipelineWorkload(),
        observationWorkload(changeCount: 1_000),
    ]
}

@MainActor
private func imagePipelineWorkload() -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "resource",
        name: "image-coalescing-cache-expiry-cancellation",
        inputSize: 6,
        seed: 0x494d_4147_4552_4551,
        budgets: [
            .exact("coalesced_resolver_calls", 1),
            .exact("coalesced_completions", 2),
            .exact("cache_hit_additional_resolver_calls", 0),
            .exact("negative_entries_before_expiry", 1),
            .exact("negative_entries_after_expiry", 1),
            .exact("cancelled_consumers", 0),
            .exact("retained_after_teardown", 0),
            .maximum("cache_entries", 1),
        ],
        body: {
            let clock = ManualUIClock()
            let resolverState = BenchmarkImageResolver()
            let resolver = ImageSourceResolver { query in
                await resolverState.resolve(query)
            }
            let pipeline = ImageRequestPipeline(
                resourceHostHandle: 1,
                clock: clock.clock,
                resolver: resolver,
                limits: ImageRequestCacheLimits(
                    maximumEntries: 8,
                    maximumDecodedBytes: 8 * 1_024 * 1_024,
                    maximumNegativeEntries: 8,
                    maximumInFlightRequests: 4,
                    negativeResultLifetime: .milliseconds(5)))

            func request(_ id: UInt64, icon: String) -> ImageRequest {
                ImageRequest(
                    id: ImageRequestID(rawValue: id),
                    source: .icon(name: icon, theme: "benchmark"),
                    targetSize: Size(width: 64, height: 64),
                    appearance: .dark,
                    cancellationGeneration: 1)
            }

            var completions: UInt64 = 0
            var successes: UInt64 = 0
            let first = pipeline.request(request(1, icon: "present")) { result in
                completions &+= 1
                if case .success = result.outcome { successes &+= 1 }
            }
            let second = pipeline.request(request(2, icon: "present")) { result in
                completions &+= 1
                if case .success = result.outcome { successes &+= 1 }
            }
            try await waitUntil("coalesced image completions") {
                completions == 2
            }
            consume(first)
            consume(second)
            let callsAfterCoalescing = await resolverState.callCount

            let third = pipeline.request(request(3, icon: "present")) { result in
                completions &+= 1
                if case .success = result.outcome { successes &+= 1 }
            }
            consume(third)
            let callsAfterCacheHit = await resolverState.callCount
            guard completions == 3, successes == 3 else {
                throw BenchmarkFailure.semantic(
                    "image cache hit did not complete synchronously")
            }

            var missingFailures: UInt64 = 0
            var missingTokens: [ImageRequestToken] = []
            missingTokens.append(pipeline.request(request(4, icon: "missing")) {
                if case .failure(.unresolved) = $0.outcome {
                    missingFailures &+= 1
                }
            })
            try await waitUntil("first negative image completion") {
                missingFailures == 1
            }
            let negativeBeforeExpiry = pipeline.negativeEntryCount

            missingTokens.append(pipeline.request(request(5, icon: "missing")) {
                if case .failure(.unresolved) = $0.outcome {
                    missingFailures &+= 1
                }
            })
            guard missingFailures == 2 else {
                throw BenchmarkFailure.semantic(
                    "negative image cache did not complete synchronously")
            }
            clock.advance(by: .milliseconds(5))
            missingTokens.append(pipeline.request(request(6, icon: "missing")) {
                if case .failure(.unresolved) = $0.outcome {
                    missingFailures &+= 1
                }
            })
            try await waitUntil("expired negative image completion") {
                missingFailures == 3
            }
            let negativeAfterExpiry = pipeline.negativeEntryCount
            consume(missingTokens)

            let cancellationResolver = BenchmarkImageResolver(suspends: true)
            let cancellationPipeline = ImageRequestPipeline(
                resourceHostHandle: 1,
                resolver: ImageSourceResolver { query in
                    await cancellationResolver.resolve(query)
                })
            var cancellationCompletions: UInt64 = 0
            let cancellationToken = cancellationPipeline.request(
                request(7, icon: "cancelled")) { _ in
                    cancellationCompletions &+= 1
                }
            cancellationToken.cancel()
            try await waitUntil("image cancellation drain") {
                cancellationPipeline.inFlightRequestCount == 0
                    && cancellationPipeline.consumerCount == 0
            }
            cancellationResolver.resume()
            cancellationPipeline.shutdown()

            let cachedEntries = pipeline.cachedEntryCount
            let cachedBytes = pipeline.cachedDecodedByteCost
            let resolverCalls = await resolverState.callCount
            guard resolverCalls == callsAfterCoalescing + 2 else {
                throw BenchmarkFailure.semantic(
                    "image negative-cache expiry used the wrong resolver count")
            }
            pipeline.shutdown()
            let retained = pipeline.cachedEntryCount
                + pipeline.negativeEntryCount
                + pipeline.inFlightRequestCount
                + pipeline.consumerCount
                + cancellationPipeline.cachedEntryCount
                + cancellationPipeline.negativeEntryCount
                + cancellationPipeline.inFlightRequestCount
                + cancellationPipeline.consumerCount
            var checksum: UInt64 = successes
            checksum.mix(missingFailures)
            checksum.mix(UInt64(cachedBytes))
            return BenchmarkSample(
                metrics: [
                    "coalesced_resolver_calls": UInt64(callsAfterCoalescing),
                    "coalesced_completions": 2,
                    "cache_hit_additional_resolver_calls":
                        UInt64(callsAfterCacheHit - callsAfterCoalescing),
                    "negative_entries_before_expiry":
                        UInt64(negativeBeforeExpiry),
                    "negative_entries_after_expiry": UInt64(negativeAfterExpiry),
                    "negative_failures": missingFailures,
                    "cancelled_completions": cancellationCompletions,
                    "cancelled_consumers":
                        UInt64(cancellationPipeline.consumerCount),
                    "cache_entries": UInt64(cachedEntries),
                    "cache_bytes": UInt64(cachedBytes),
                    "copied_bytes": 0,
                    "retained_after_teardown": UInt64(retained),
                ],
                semanticChecksum: checksum)
        })
}

@MainActor
private func observationWorkload(changeCount: Int) -> BenchmarkWorkload {
    BenchmarkWorkload(
        category: "resource",
        name: "observation-coalescing-\(changeCount)",
        inputSize: UInt64(changeCount),
        seed: 0x4f42_5345_5256_4552,
        budgets: [
            .exact("initial_updates", 1),
            .exact("coalesced_updates", 1),
            .exact("live_tokens_after_cancellation", 0),
            .exact("updates_after_cancellation", 0),
        ],
        body: {
            let tokenBaseline = RetainedObservationToken.liveCount
            let uiContext = UIContext(services: .inMemory())
            let model = BenchmarkObservableModel()
            var updateCount: UInt64 = 0
            var view: View?
            var token: RetainedObservationToken?
            uiContext.construct {
                let retainedView = View()
                view = retainedView
                token = retainedView.observe(
                    model,
                    capturePolicy: .strong) { view, model in
                        updateCount &+= 1
                        view.alphaValue = Double(model.value % 100) / 100
                    }
            }
            guard updateCount == 1 else {
                throw BenchmarkFailure.semantic(
                    "observation did not perform its initial projection")
            }
            for value in 1...changeCount {
                model.value = value
            }
            try await waitUntil("observation coalesced update") {
                updateCount == 2
            }
            let beforeCancellation = updateCount
            token?.cancel()
            token = nil
            model.value += 1
            await Task.yield()
            await Task.yield()
            let afterCancellation = updateCount
            consume(view)
            view = nil
            let liveAfterCancellation = RetainedObservationToken.liveCount
                - tokenBaseline
            var checksum = updateCount
            checksum.mix(UInt64(model.value))
            return BenchmarkSample(
                metrics: [
                    "initial_updates": 1,
                    "coalesced_updates": beforeCancellation - 1,
                    "observation_tokens": 1,
                    "copied_bytes": 0,
                    "live_tokens_after_cancellation":
                        UInt64(max(0, liveAfterCancellation)),
                    "updates_after_cancellation":
                        afterCancellation - beforeCancellation,
                ],
                semanticChecksum: checksum)
        })
}

@MainActor
private func waitUntil(
    _ operation: String,
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<20_000 {
        if condition() { return }
        await Task.yield()
    }
    throw BenchmarkFailure.semantic("timed out waiting for \(operation)")
}

private actor BenchmarkImageResolver {
    private(set) var callCount = 0
    private let suspends: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(suspends: Bool = false) {
        self.suspends = suspends
    }

    func resolve(_ query: ImageSourceQuery) async -> String? {
        callCount += 1
        if suspends {
            await withCheckedContinuation { continuation = $0 }
        } else {
            await Task.yield()
        }
        guard case .icon(let name, _) = query.source,
              name != "missing"
        else { return nil }
        return "/benchmark/\(name).png"
    }

    nonisolated func resume() {
        Task { await resumePending() }
    }

    private func resumePending() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Observable
private final class BenchmarkObservableModel {
    var value = 0
}
