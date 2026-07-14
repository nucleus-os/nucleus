// Bounded ring buffer + drain hash.
//
// All hashing uses wrapping arithmetic and the shared FNV-1a-style mixers below.
// Plain Swift `*`/`+`/`-` are never used for any hash or counter; only
// `&*`/`&+`/`&-`.

// MARK: - Shared FNV mixers (identical across EventQueue/RuntimeHost/AndroidRenderer)

@inline(__always)
func nucMix(_ hash: UInt32, _ value: UInt32) -> UInt32 {
    return (hash ^ value) &* 16777619
}

@inline(__always)
func nucMixU64(_ hash: UInt32, _ value: UInt64) -> UInt32 {
    var h = nucMix(hash, UInt32(truncatingIfNeeded: value))
    h = nucMix(h, UInt32(truncatingIfNeeded: value >> 32))
    return h
}

@inline(__always)
func nucMixI64(_ hash: UInt32, _ value: Int64) -> UInt32 {
    return nucMixU64(hash, UInt64(bitPattern: value))
}

@inline(__always)
func nucMixI32(_ hash: UInt32, _ value: Int32) -> UInt32 {
    return nucMix(hash, UInt32(bitPattern: value))
}

@inline(__always)
func nucMixF32(_ hash: UInt32, _ value: Float) -> UInt32 {
    let scaled = Int32(value * 1000.0)
    return nucMixI32(hash, scaled)
}

// MARK: - Event kinds

enum EventKind: Int32 {
    case none = 0
    case host_start = 1
    case host_stop = 2
    case window_attached = 3
    case window_detached = 4
    case window_focus = 5
    case configuration = 6
    case surface_attached = 7
    case surface_changed = 8
    case surface_detached = 9
    case frame = 10
    case touch = 11
    case key = 12
    case ime = 13
    case runtime_attach = 14
    case runtime_start = 15
    case runtime_frame = 16
    case runtime_stop = 17
    case runtime_detach = 18
}

struct AndroidEvent {
    var kind: EventKind = .none
    var sequence: UInt64 = 0
    var i0: Int32 = 0
    var i1: Int32 = 0
    var i2: Int32 = 0
    var i3: Int32 = 0
    var f0: Float = 0
    var f1: Float = 0
    var f2: Float = 0
    var time_nanos: Int64 = 0
    var flag: Bool = false
}

struct DrainStats {
    var count: UInt32 = 0
    var hash: UInt32 = 2166136261
    var dropped_count: UInt64 = 0

    func smokeValue() -> Int32 {
        var value = nucMix(hash, count)
        value = nucMixU64(value, dropped_count)
        return Int32(value & 0x7fffffff)
    }
}

// MARK: - Bounded ring buffer

struct AndroidEventQueue {
    static let capacity = 64

    var events: [AndroidEvent] = Array(repeating: AndroidEvent(), count: AndroidEventQueue.capacity)
    var head: Int = 0
    var len: Int = 0
    var next_sequence: UInt64 = 1
    var dropped_count: UInt64 = 0

    func queuedCount() -> UInt32 {
        return UInt32(len)
    }

    func droppedCount() -> UInt64 {
        return dropped_count
    }

    mutating func push(_ event: AndroidEvent) {
        var item = event
        item.sequence = next_sequence
        next_sequence &+= 1
        if next_sequence == 0 {
            next_sequence = 1
        }

        if len == AndroidEventQueue.capacity {
            head = (head + 1) % AndroidEventQueue.capacity
            len -= 1
            dropped_count &+= 1
        }

        let tail = (head + len) % AndroidEventQueue.capacity
        events[tail] = item
        len += 1
    }

    mutating func drainSmokeValue() -> Int32 {
        return drainStats().smokeValue()
    }

    mutating func drainStats() -> DrainStats {
        var stats = DrainStats(count: 0, hash: 2166136261, dropped_count: dropped_count)
        while let event = pop() {
            stats.count &+= 1
            stats.hash = nucMix(stats.hash, UInt32(bitPattern: event.kind.rawValue))
            stats.hash = nucMixU64(stats.hash, event.sequence)
            stats.hash = nucMixI32(stats.hash, event.i0)
            stats.hash = nucMixI32(stats.hash, event.i1)
            stats.hash = nucMixI32(stats.hash, event.i2)
            stats.hash = nucMixI32(stats.hash, event.i3)
            stats.hash = nucMixF32(stats.hash, event.f0)
            stats.hash = nucMixF32(stats.hash, event.f1)
            stats.hash = nucMixF32(stats.hash, event.f2)
            stats.hash = nucMixI64(stats.hash, event.time_nanos)
            stats.hash = nucMix(stats.hash, event.flag ? 1 : 0)
        }
        return stats
    }

    private mutating func pop() -> AndroidEvent? {
        if len == 0 { return nil }
        let event = events[head]
        head = (head + 1) % AndroidEventQueue.capacity
        len -= 1
        return event
    }
}
