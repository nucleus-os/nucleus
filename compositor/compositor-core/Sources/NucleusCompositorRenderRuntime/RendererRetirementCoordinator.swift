package import NucleusCompositorRendererLinux

/// Value state machine for the host-visible portion of renderer retirement.
/// The compositor runtime remains the sole owner of libseat, topology, and the
/// renderer; this value only makes retry/deadline decisions explicit and
/// deterministic.
package struct RendererRetirementCoordinator: Sendable {
    package enum ShutdownDisposition: Sendable, Equatable {
        case outputsDisabled
        case drmDeviceCloseRequired
    }

    package enum Phase: Sendable, Equatable {
        case active
        case pausing(retryAtNanoseconds: UInt64)
        case paused
        case shuttingDown(
            deadlineNanoseconds: UInt64,
            retryAtNanoseconds: UInt64)
        case finished(ShutdownDisposition)
    }

    package enum PauseDecision: Sendable, Equatable {
        case waiting(retryAtNanoseconds: UInt64)
        case acknowledge(cleanlyRetired: Bool)
    }

    package enum ShutdownDecision: Sendable, Equatable {
        case waiting(
            retryAtNanoseconds: UInt64,
            deadlineNanoseconds: UInt64)
        case readyToExit(ShutdownDisposition)
    }

    package private(set) var phase: Phase = .active
    package let retryDelayNanoseconds: UInt64
    package let shutdownGraceNanoseconds: UInt64

    package init(
        retryDelayNanoseconds: UInt64,
        shutdownGraceNanoseconds: UInt64
    ) {
        precondition(retryDelayNanoseconds > 0)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.shutdownGraceNanoseconds = shutdownGraceNanoseconds
    }

    package var hasStartedShutdown: Bool {
        switch phase {
        case .shuttingDown, .finished:
            true
        case .active, .pausing, .paused:
            false
        }
    }

    package var pauseRetryDeadlineNanoseconds: UInt64? {
        guard case .pausing(let retryAt) = phase else { return nil }
        return retryAt
    }

    package var shutdownRetryDeadlineNanoseconds: UInt64? {
        guard case .shuttingDown(_, let retryAt) = phase else { return nil }
        return retryAt
    }

    package func pauseRetryIsDue(at nowNanoseconds: UInt64) -> Bool {
        guard let retryAt = pauseRetryDeadlineNanoseconds else { return false }
        return nowNanoseconds >= retryAt
    }

    package mutating func applyPauseResult(
        _ result: RendererRetirementResult,
        nowNanoseconds: UInt64
    ) -> PauseDecision {
        precondition(
            !hasStartedShutdown,
            "a session pause cannot replace shutdown retirement")
        switch result {
        case .complete:
            phase = .paused
            return .acknowledge(cleanlyRetired: true)
        case .failed:
            phase = .paused
            return .acknowledge(cleanlyRetired: false)
        case .draining:
            let retryAt = addingClamped(
                nowNanoseconds, retryDelayNanoseconds)
            phase = .pausing(retryAtNanoseconds: retryAt)
            return .waiting(retryAtNanoseconds: retryAt)
        }
    }

    package mutating func noteResume(succeeded: Bool) {
        phase = succeeded ? .active : .paused
    }

    package mutating func applyShutdownResult(
        _ result: RendererRetirementResult,
        nowNanoseconds: UInt64
    ) -> ShutdownDecision {
        if case .finished(let disposition) = phase {
            return .readyToExit(disposition)
        }
        let deadline: UInt64
        if case .shuttingDown(let existingDeadline, _) = phase {
            deadline = existingDeadline
        } else {
            deadline = addingClamped(
                nowNanoseconds, shutdownGraceNanoseconds)
        }

        switch result {
        case .complete:
            phase = .finished(.outputsDisabled)
            return .readyToExit(.outputsDisabled)
        case .failed:
            phase = .finished(.drmDeviceCloseRequired)
            return .readyToExit(.drmDeviceCloseRequired)
        case .draining where nowNanoseconds >= deadline:
            phase = .finished(.drmDeviceCloseRequired)
            return .readyToExit(.drmDeviceCloseRequired)
        case .draining:
            let retryAt = min(
                addingClamped(nowNanoseconds, retryDelayNanoseconds),
                deadline)
            phase = .shuttingDown(
                deadlineNanoseconds: deadline,
                retryAtNanoseconds: retryAt)
            return .waiting(
                retryAtNanoseconds: retryAt,
                deadlineNanoseconds: deadline)
        }
    }
}

private func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
}
