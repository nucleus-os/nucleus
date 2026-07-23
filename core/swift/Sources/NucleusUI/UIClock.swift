/// A context-owned monotonic clock for portable interaction deadlines.
///
/// The value seam keeps scheduler policy out of views: production contexts use
/// `ContinuousClock`, while semantic tests inject a manually advanced source.
/// Animation sampling continues to use presentation timestamps instead.
public struct UIClock: Sendable {
    public struct Instant: RawRepresentable, Comparable, Hashable, Sendable {
        public let rawValue: UInt64

        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public func advanced(by duration: Duration) -> Instant {
            let delta = UIClock.saturatingNanoseconds(duration)
            let result = rawValue.addingReportingOverflow(delta)
            return Instant(rawValue: result.overflow ? .max : result.partialValue)
        }
    }

    private let nowBody: @MainActor @Sendable () -> Instant
    private let sleepUntilBody:
        @MainActor @Sendable (Instant) async throws -> Void

    package init(
        now: @escaping @MainActor @Sendable () -> Instant,
        sleepUntil:
            @escaping @MainActor @Sendable (Instant) async throws -> Void
    ) {
        nowBody = now
        sleepUntilBody = sleepUntil
    }

    @MainActor
    public var now: Instant { nowBody() }

    @MainActor
    public func deadline(after duration: Duration) -> Instant {
        now.advanced(by: duration)
    }

    @MainActor
    public func sleep(until deadline: Instant) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        try await sleepUntilBody(deadline)
    }

    @MainActor
    public func sleep(for duration: Duration) async throws {
        try await sleep(until: deadline(after: duration))
    }

    public static let continuous: UIClock = {
        let clock = ContinuousClock()
        let origin = clock.now
        return UIClock(
            now: {
                Instant(rawValue: saturatingNanoseconds(
                    origin.duration(to: clock.now)))
            },
            sleepUntil: { deadline in
                let duration = Duration.nanoseconds(
                    Int64(clamping: deadline.rawValue))
                try await clock.sleep(until: origin.advanced(by: duration))
            })
    }()

    package static func saturatingNanoseconds(
        _ duration: Duration
    ) -> UInt64 {
        guard duration > .zero else { return 0 }
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let whole = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return .max }
        let fractional = UInt64(max(0, components.attoseconds)) / 1_000_000_000
        let result = whole.partialValue.addingReportingOverflow(fractional)
        return result.overflow ? .max : result.partialValue
    }
}

/// Deterministic test clock. Ready continuations are signaled in insertion
/// order and are removed exactly once by deadline advancement or task
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
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(
                    id: waiterID,
                    deadline: deadline,
                    continuation: continuation))
            }
        }, onCancel: {
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
