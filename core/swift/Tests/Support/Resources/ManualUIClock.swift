import NucleusUI

/// Deterministic test and benchmark clock. Ready continuations are signaled in
/// insertion order and are removed exactly once by deadline advancement or task
/// cancellation. The executor may run the resumed tasks in either order.
@MainActor
package final class ManualUIClock {
    private struct Waiter {
        let id: UInt64
        let deadline: UIClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var current = UIClock.Instant(rawValue: 0)
    private var nextWaiterID: UInt64 = 1
    private var waiters: [Waiter] = []

    package init() {}

    package var clock: UIClock {
        UIClock(
            now: { [weak self] in
                self?.current ?? UIClock.Instant(rawValue: .max)
            },
            sleepUntil: { [weak self] deadline in
                guard let self else { throw CancellationError() }
                try await self.sleep(until: deadline)
            })
    }

    package var now: UIClock.Instant { current }
    package var waiterCount: Int { waiters.count }

    package func advance(by duration: Duration) {
        advance(to: current.advanced(by: duration))
    }

    package func advance(to instant: UIClock.Instant) {
        precondition(instant >= current, "manual UI clock cannot move backward")
        current = instant
        let ready = waiters.filter { $0.deadline <= current }
        guard !ready.isEmpty else { return }
        let readyIDs = Set(ready.map(\.id))
        waiters.removeAll { readyIDs.contains($0.id) }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func sleep(until deadline: UIClock.Instant) async throws {
        try Task.checkCancellation()
        guard deadline > current else { return }
        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        precondition(nextWaiterID != 0, "manual UI clock waiter identity exhausted")
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    waiters.append(
                        Waiter(
                            id: waiterID,
                            deadline: deadline,
                            continuation: continuation))
                }
            },
            onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancel(waiterID)
                }
            })
    }

    private func cancel(_ waiterID: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
