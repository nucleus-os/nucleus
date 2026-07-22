import Glibc

/// Converts kernel DRM event timestamps into the one clock domain Nucleus
/// advertises to Wayland clients.
struct DrmPresentationClock: Sendable, Equatable {
    static let clockID = UInt32(CLOCK_MONOTONIC)
    let kernelUsesMonotonic: Bool

    func normalize(_ kernelTimestampNs: UInt64) -> UInt64? {
        guard !kernelUsesMonotonic else { return kernelTimestampNs }
        var monotonic = timespec()
        var realtime = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &monotonic) == 0,
            clock_gettime(CLOCK_REALTIME, &realtime) == 0
        else { return nil }
        return Self.convertRealtimeToMonotonic(
            kernelTimestampNs,
            monotonicNowNs: Self.nanoseconds(monotonic),
            realtimeNowNs: Self.nanoseconds(realtime))
    }

    static func convertRealtimeToMonotonic(
        _ realtimeTimestampNs: UInt64,
        monotonicNowNs: UInt64,
        realtimeNowNs: UInt64
    ) -> UInt64? {
        if monotonicNowNs >= realtimeNowNs {
            let delta = monotonicNowNs - realtimeNowNs
            let result = realtimeTimestampNs.addingReportingOverflow(delta)
            return result.overflow ? nil : result.partialValue
        }
        let delta = realtimeNowNs - monotonicNowNs
        guard realtimeTimestampNs >= delta else { return nil }
        return realtimeTimestampNs - delta
    }

    private static func nanoseconds(_ value: timespec) -> UInt64 {
        UInt64(value.tv_sec) &* 1_000_000_000 &+ UInt64(value.tv_nsec)
    }
}

/// Extends a CRTC's wrapping 32-bit kernel sequence into an ordered 64-bit
/// sequence. Backward/duplicate samples that are not a wrap are rejected.
struct DrmSequenceExtender: Sendable, Equatable {
    private(set) var lastRaw: UInt32?
    private(set) var extended: UInt64 = 0

    mutating func extend(_ raw: UInt32) -> UInt64? {
        guard let lastRaw else {
            self.lastRaw = raw
            extended = UInt64(raw)
            return extended
        }
        let delta = raw &- lastRaw
        guard delta != 0, delta < 0x8000_0000 else { return nil }
        extended &+= UInt64(delta)
        self.lastRaw = raw
        return extended
    }
}

struct DrmPresentationEventState: Sendable, Equatable {
    private var sequence = DrmSequenceExtender()
    private(set) var lastTimestampNs: UInt64?
    private(set) var lastSequence: UInt64?

    mutating func accept(
        _ raw: DrmPageFlipEvent,
        clock: DrmPresentationClock
    ) -> (timestampNs: UInt64, sequence: UInt64)? {
        guard let timestamp = clock.normalize(raw.timestampNs) else { return nil }
        if let lastTimestampNs, timestamp < lastTimestampNs { return nil }
        var proposedSequence = sequence
        let extended: UInt64
        if let kernelSequence = proposedSequence.extend(raw.sequence) {
            if let lastSequence, kernelSequence <= lastSequence {
                let next = lastSequence.addingReportingOverflow(1)
                guard !next.overflow else { return nil }
                extended = next.partialValue
            } else {
                extended = kernelSequence
            }
            sequence = proposedSequence
        } else if raw.sequence == 0,
            let lastTimestampNs,
            timestamp > lastTimestampNs,
            let lastSequence
        {
            // NVIDIA's proprietary KMS driver can report sequence zero for
            // every page flip. In that case the increasing kernel timestamp is
            // the ordering authority and we synthesize the missing sequence.
            let next = lastSequence.addingReportingOverflow(1)
            guard !next.overflow else { return nil }
            extended = next.partialValue
        } else {
            return nil
        }
        lastTimestampNs = timestamp
        lastSequence = extended
        return (timestamp, extended)
    }
}
