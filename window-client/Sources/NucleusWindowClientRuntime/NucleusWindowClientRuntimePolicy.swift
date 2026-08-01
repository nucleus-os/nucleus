import Glibc
import NucleusLinuxPrimitives

package enum NucleusWindowClientMonotonicClock {
    package static func nowNanoseconds() -> UInt64 {
        LinuxMonotonicClock.nowNanoseconds()
    }
}

/// Classification of one poll descriptor's returned events.
package struct NucleusWindowClientPollResult: Sendable, Equatable {
    package let revents: Int16

    package init(revents: Int16) {
        self.revents = revents
    }

    package var isReadable: Bool { revents & Int16(POLLIN) != 0 }
    package var isWritable: Bool { revents & Int16(POLLOUT) != 0 }
    package var isHungUp: Bool { revents & Int16(POLLHUP) != 0 }
    package var isInvalid: Bool { revents & Int16(POLLNVAL) != 0 }
    package var hasError: Bool { revents & Int16(POLLERR) != 0 }
    package var isTerminal: Bool { isHungUp || isInvalid || hasError }
}

package enum NucleusWindowClientPollInterestPolicy {
    /// A source with no requested events remains deadline-driven; submitting it
    /// to poll/io_uring would be an invalid zero-event registration.
    package static func shouldRegister(
        fileDescriptor: Int32,
        events: Int16
    ) -> Bool {
        fileDescriptor >= 0 && events != 0
    }
}

package enum NucleusWindowClientFlushDisposition: Sendable, Equatable {
    case flushed
    case needsWrite
    case disconnected(error: Int32)

    package static func classify(result: Int32, error: Int32) -> Self {
        guard result < 0 else { return .flushed }
        return error == EAGAIN
            ? .needsWrite
            : .disconnected(error: error)
    }
}

/// Accumulates relative event-loop deadlines and produces poll's timeout.
package struct NucleusWindowClientDeadlineSet: Sendable, Equatable {
    package private(set) var earliestNanoseconds: UInt64?

    package init() {}

    package mutating func add(relativeNanoseconds value: UInt64?) {
        guard let value else { return }
        earliestNanoseconds = min(earliestNanoseconds ?? value, value)
    }

    package mutating func add(relativeMicroseconds value: UInt64?) {
        guard let value else { return }
        let nanoseconds = value.multipliedReportingOverflow(by: 1_000)
        add(relativeNanoseconds: nanoseconds.overflow ? UInt64.max : nanoseconds.partialValue)
    }

    /// `-1` means infinite. Finite waits round up so poll does not wake before
    /// the earliest nanosecond deadline merely because it accepts milliseconds.
    package var pollTimeoutMilliseconds: Int32 {
        guard let nanoseconds = earliestNanoseconds else { return -1 }
        let milliseconds =
            nanoseconds / 1_000_000
            + (nanoseconds % 1_000_000 == 0 ? 0 : 1)
        return Int32(clamping: milliseconds)
    }
}

package enum NucleusWindowClientPresentationTiming {
    /// Convert wl_output's millihertz unit to a nanosecond interval.
    package static func intervalNanoseconds(refreshMillihertz: Int32) -> UInt64? {
        guard refreshMillihertz > 0 else { return nil }
        return 1_000_000_000_000 / UInt64(refreshMillihertz)
    }

    /// Advance one interval from a live deadline, or rebase after a stall.
    package static func nextDeadline(
        previous: UInt64?,
        now: UInt64,
        interval: UInt64
    ) -> UInt64 {
        guard interval > 0 else { return now }
        guard let previous, previous >= now.saturatingSubtract(interval) else {
            return now.saturatingAdd(interval)
        }
        let candidate = previous.saturatingAdd(interval)
        return candidate > now ? candidate : now.saturatingAdd(interval)
    }
}

package enum NucleusWindowClientFrameDecision {
    package static func shouldRender(
        workPending: Bool,
        deadline: UInt64?,
        now: UInt64
    ) -> Bool {
        workPending && deadline.map { $0 <= now } == true
    }
}

extension UInt64 {
    fileprivate func saturatingAdd(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }

    fileprivate func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
