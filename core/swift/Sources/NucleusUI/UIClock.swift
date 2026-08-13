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
    private let sleepUntilBody: @MainActor @Sendable (Instant) async throws -> Void

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
                Instant(
                    rawValue: saturatingNanoseconds(
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
