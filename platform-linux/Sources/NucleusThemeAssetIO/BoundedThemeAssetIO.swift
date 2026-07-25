import Dispatch

/// A process-local filesystem worker with bounded pending work, duplicate
/// coalescing, and a cost-bounded completed-result LRU.
///
/// `processor` is the only closure that may touch the filesystem. It runs on a
/// dedicated concurrent queue, never on the caller's actor or Swift's
/// cooperative executor.
public actor BoundedThemeAssetIO<
    Key: Hashable & Sendable,
    Value: Sendable
> {
    public typealias Processor = @Sendable (Key) -> Value?
    public typealias Cost = @Sendable (Value) -> Int

    private struct CacheEntry {
        var value: Value
        var cost: Int
    }

    private let maximumPending: Int
    private let maximumConcurrent: Int
    private let maximumCompletedEntries: Int
    private let maximumCompletedCost: Int
    private let processor: Processor
    private let cost: Cost
    private let queue: DispatchQueue

    private var pending: [Key] = []
    private var running: Set<Key> = []
    private var waiters: [Key: [CheckedContinuation<Value?, Never>]] = [:]
    private var completed: [Key: CacheEntry] = [:]
    private var lru: [Key] = []
    private var completedCost = 0

    public init(
        label: String,
        maximumPending: Int = 256,
        maximumConcurrent: Int = 2,
        maximumCompletedEntries: Int,
        maximumCompletedCost: Int = .max,
        cost: @escaping Cost = { _ in 1 },
        processor: @escaping Processor
    ) {
        precondition(maximumPending > 0)
        precondition(maximumConcurrent > 0)
        precondition(maximumCompletedEntries > 0)
        precondition(maximumCompletedCost >= 0)
        self.maximumPending = maximumPending
        self.maximumConcurrent = maximumConcurrent
        self.maximumCompletedEntries = maximumCompletedEntries
        self.maximumCompletedCost = maximumCompletedCost
        self.cost = cost
        self.processor = processor
        queue = DispatchQueue(
            label: label,
            qos: .userInitiated,
            attributes: .concurrent)
    }

    public func resolve(_ key: Key) async -> Value? {
        if let entry = completed[key] {
            touch(key)
            return entry.value
        }
        return await withCheckedContinuation { continuation in
            if waiters[key] != nil {
                waiters[key, default: []].append(continuation)
                return
            }
            waiters[key] = [continuation]
            if running.count < maximumConcurrent {
                start(key)
                return
            }
            if pending.count == maximumPending {
                let dropped = pending.removeFirst()
                let droppedWaiters = waiters.removeValue(forKey: dropped) ?? []
                for waiter in droppedWaiters { waiter.resume(returning: nil) }
            }
            pending.append(key)
        }
    }

    public func invalidateAll() {
        completed.removeAll(keepingCapacity: true)
        lru.removeAll(keepingCapacity: true)
        completedCost = 0
    }

    public var snapshot: Snapshot {
        Snapshot(
            pending: pending.count,
            running: running.count,
            completed: completed.count,
            completedCost: completedCost)
    }

    public struct Snapshot: Sendable, Equatable {
        public var pending: Int
        public var running: Int
        public var completed: Int
        public var completedCost: Int
    }

    private func start(_ key: Key) {
        running.insert(key)
        let processor = self.processor
        let queue = self.queue
        queue.async { [weak self] in
            let value = processor(key)
            Task { await self?.finish(key, value: value) }
        }
    }

    private func finish(_ key: Key, value: Value?) {
        running.remove(key)
        if let value {
            insert(value, for: key)
        }
        let continuations = waiters.removeValue(forKey: key) ?? []
        for continuation in continuations {
            continuation.resume(returning: value)
        }
        while running.count < maximumConcurrent, !pending.isEmpty {
            start(pending.removeFirst())
        }
    }

    private func insert(_ value: Value, for key: Key) {
        let entryCost = max(0, cost(value))
        guard entryCost <= maximumCompletedCost else { return }
        if let previous = completed.removeValue(forKey: key) {
            completedCost -= previous.cost
            lru.removeAll { $0 == key }
        }
        completed[key] = CacheEntry(value: value, cost: entryCost)
        lru.append(key)
        completedCost += entryCost
        while completed.count > maximumCompletedEntries
                || completedCost > maximumCompletedCost
        {
            guard !lru.isEmpty else { break }
            let evicted = lru.removeFirst()
            if let entry = completed.removeValue(forKey: evicted) {
                completedCost -= entry.cost
            }
        }
    }

    private func touch(_ key: Key) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }
}
