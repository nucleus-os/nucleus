// InputLatencyProbe — per-event input-delivery latency probe (Swift owner).
//
// It measures the libinput-ingress → seat-wire-send latency across the single
// dispatch choke point, but only for genuine libinput events;
// synthetic/replayed events `clear()` it so their sends are not attributed to a
// stale ingress. `markDelivery` folds each hot seat send's ingress→send delta into a
// per-kind log2 histogram dumped on a cadence and on demand.
//
// Dispatch is single-threaded on the compositor main actor and processes one event
// end-to-end before the next, so the one ingress slot needs no synchronization.

import Glibc

/// log2(ns) buckets: bucket b holds [2^b, 2^(b+1)) ns. 32 buckets reach ~4.3 s,
/// far past any sane dispatch latency, so nothing saturates the top. File-level so
/// the `Stat` default-value context is nonisolated.
private let latencyBucketCount = 32

@MainActor
enum InputLatencyProbe {
    enum Kind: Int {
        case pointerMotion = 0
        case pointerButton = 1
        case keyboardKey = 2

        var label: String {
            switch self {
            case .pointerMotion: return "pointer-motion"
            case .pointerButton: return "pointer-button"
            case .keyboardKey: return "keyboard-key"
            }
        }
    }

    private struct Stat {
        var count: UInt64 = 0
        var sumNs: UInt64 = 0
        var minNs: UInt64 = .max
        var maxNs: UInt64 = 0
        var buckets = [UInt64](repeating: 0, count: latencyBucketCount)

        mutating func record(_ ns: UInt64) {
            count += 1
            sumNs += ns
            if ns < minNs { minNs = ns }
            if ns > maxNs { maxNs = ns }
            let b = ns == 0 ? 0 : min(latencyBucketCount - 1, 63 - ns.leadingZeroBitCount)
            buckets[b] += 1
        }

        /// Lower edge (2^b ns) of the bucket holding the `q`-quantile sample.
        func quantileNs(_ q: Double) -> UInt64 {
            if count == 0 { return 0 }
            let target = UInt64((q * Double(count)).rounded(.up))
            var cumulative: UInt64 = 0
            for (b, c) in buckets.enumerated() {
                cumulative += c
                if cumulative >= target { return UInt64(1) << UInt64(b) }
            }
            return maxNs
        }
    }

    /// Emit a baseline dump every this-many measured deliveries.
    private static let dumpEvery: UInt64 = 2000

    private static var ingress: UInt64?
    private static var stats = [Stat](repeating: Stat(), count: 3)
    private static var sinceDump: UInt64 = 0

    private static func nsNow() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    /// Stamp ingress for a genuine libinput event at dispatch entry.
    static func beginHidEvent() { ingress = nsNow() }

    /// Drop the ingress stamp: a synthetic/replayed event is being dispatched, so a
    /// hot send during it is not a libinput→client delivery and must not be measured.
    static func clear() { ingress = nil }

    /// Record the ingress→now delta for a delivered hot seat event.
    static func markDelivery(_ kind: Kind) {
        guard let start = ingress else { return }
        let now = nsNow()
        let ns = now > start ? now - start : 0
        stats[kind.rawValue].record(ns)
        sinceDump += 1
        if sinceDump >= dumpEvery {
            dump()
            sinceDump = 0
        }
    }

    /// Log the per-kind latency distribution (greppable `input-latency:` lines).
    static func dump() {
        for (i, s) in stats.enumerated() {
            if s.count == 0 { continue }
            let kind = Kind(rawValue: i)!
            let line = "input-latency: \(kind.label) n=\(s.count)"
                + " min=\(us(s.minNs))us mean=\(us(s.sumNs / s.count))us"
                + " p50=\(us(s.quantileNs(0.50)))us p99=\(us(s.quantileNs(0.99)))us"
                + " max=\(us(s.maxNs))us\n"
            line.withCString { _ = write(2, $0, strlen($0)) }
        }
    }

    /// Nanoseconds as microseconds with one decimal, without Foundation's
    /// `String(format:)` (the runtime files avoid Foundation).
    private static func us(_ ns: UInt64) -> String {
        let whole = ns / 1000
        let tenths = (ns % 1000) / 100
        return "\(whole).\(tenths)"
    }
}
