@MainActor
public final class IdlePolicy {
    public init() {}

    private struct Notification {
        var id: UInt64
        var timeoutMS: UInt32
        var idled: Bool = false
    }

    private var lastInputNS: UInt64 = 0
    private var inhibitorCount: UInt32 = 0
    private var notifications: [UInt64: Notification] = [:]

    public func registerNotification(id: UInt64, timeoutMS: UInt32) {
        notifications[id] = Notification(id: id, timeoutMS: timeoutMS)
    }

    public func unregisterNotification(id: UInt64) {
        notifications[id] = nil
    }

    public func inhibitInc() {
        inhibitorCount &+= 1
    }

    public func inhibitDec() {
        if inhibitorCount > 0 {
            inhibitorCount -= 1
        }
    }

    public func noteInput(nowNS: UInt64, max: Int) -> [UInt64] {
        lastInputNS = nowNS
        // noteInput runs on every input event (pointer motion is high-frequency); skip
        // the sort + allocation entirely when there are no notifications to resume.
        guard !notifications.isEmpty else { return [] }
        var resumed: [UInt64] = []
        resumed.reserveCapacity(min(max, notifications.count))
        for id in notifications.keys.sorted() {
            guard resumed.count < max, notifications[id]?.idled == true else { continue }
            notifications[id]?.idled = false
            resumed.append(id)
        }
        return resumed
    }

    public func nextDeadlineNS(nowNS: UInt64) -> UInt64? {
        _ = nowNS
        if inhibitorCount > 0 { return nil }
        var minDeadline: UInt64?
        for notification in notifications.values {
            if notification.idled { continue }
            let deadline = lastInputNS &+ (UInt64(notification.timeoutMS) &* 1_000_000)
            if minDeadline == nil || deadline < minDeadline! {
                minDeadline = deadline
            }
        }
        return minDeadline
    }

    public func tick(nowNS: UInt64, max: Int) -> [UInt64] {
        if inhibitorCount > 0 { return [] }
        guard !notifications.isEmpty else { return [] }
        var idled: [UInt64] = []
        idled.reserveCapacity(min(max, notifications.count))
        for id in notifications.keys.sorted() {
            guard idled.count < max, let notification = notifications[id], !notification.idled else { continue }
            let deadline = lastInputNS &+ (UInt64(notification.timeoutMS) &* 1_000_000)
            if nowNS >= deadline {
                notifications[id]?.idled = true
                idled.append(id)
            }
        }
        return idled
    }
}
