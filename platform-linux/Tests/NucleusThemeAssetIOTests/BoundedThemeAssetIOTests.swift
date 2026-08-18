import Dispatch
import Synchronization
import Testing

@testable import NucleusThemeAssetIO

@Suite struct BoundedThemeAssetIOTests {
    @Test func coalescesDuplicatesAndCachesCompletedValues() async {
        let calls = Mutex(0)
        let service = BoundedThemeAssetIO<Int, Int>(
            label: "theme-io-test",
            maximumCompletedEntries: 4
        ) { key in
            calls.withLock { $0 += 1 }
            return key * 2
        }
        async let first = service.resolve(4)
        async let second = service.resolve(4)
        #expect(await first == 8)
        #expect(await second == 8)
        #expect(await service.resolve(4) == 8)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func evictsByEntryAndCostBounds() async {
        let service = BoundedThemeAssetIO<Int, Int>(
            label: "theme-io-lru-test",
            maximumCompletedEntries: 2,
            maximumCompletedCost: 5,
            cost: { $0 }
        ) { $0 }
        #expect(await service.resolve(2) == 2)
        #expect(await service.resolve(3) == 3)
        #expect(await service.resolve(4) == 4)
        let snapshot = await service.snapshot
        #expect(snapshot.completed == 1)
        #expect(snapshot.completedCost == 4)
    }

    @Test func aCacheHitMovesTheEntryToTheEvictionTail() async {
        let calls = Mutex<[Int: Int]>([:])
        let service = BoundedThemeAssetIO<Int, Int>(
            label: "theme-io-touch-test",
            maximumCompletedEntries: 2
        ) { key in
            calls.withLock { $0[key, default: 0] += 1 }
            return key
        }
        #expect(await service.resolve(1) == 1)
        #expect(await service.resolve(2) == 2)
        // The hit on the oldest entry makes it the newest, so admitting a third
        // entry evicts 2 rather than 1.
        #expect(await service.resolve(1) == 1)
        #expect(await service.resolve(3) == 3)

        #expect(await service.resolve(1) == 1)
        #expect(calls.withLock { $0[1] } == 1)
        #expect(await service.resolve(2) == 2)
        #expect(calls.withLock { $0[2] } == 2)
    }

    @Test func dropsTheOldestNonStartedRequestAtTheQueueBound() async {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let service = BoundedThemeAssetIO<Int, Int>(
            label: "theme-io-overflow-test",
            maximumPending: 1,
            maximumConcurrent: 1,
            maximumCompletedEntries: 4
        ) { key in
            if key == 1 {
                started.signal()
                gate.wait()
            }
            return key
        }
        let first = Task { await service.resolve(1) }
        started.wait()
        let dropped = Task { await service.resolve(2) }
        while await service.snapshot.pending != 1 {
            await Task.yield()
        }
        let retained = Task { await service.resolve(3) }
        #expect(await dropped.value == nil)
        gate.signal()
        #expect(await first.value == 1)
        #expect(await retained.value == 3)
    }

    @MainActor
    @Test func aBlockedFilesystemWorkerDoesNotBlockMainActorWork() async {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let service = BoundedThemeAssetIO<Int, Int>(
            label: "theme-io-main-actor-test",
            maximumCompletedEntries: 1
        ) { key in
            started.signal()
            gate.wait()
            return key
        }
        let resolution = Task { await service.resolve(1) }
        await Task.detached { started.wait() }.value
        var sentinelRan = false
        let sentinel = Task { @MainActor in sentinelRan = true }
        await sentinel.value
        #expect(sentinelRan)
        gate.signal()
        #expect(await resolution.value == 1)
    }
}
