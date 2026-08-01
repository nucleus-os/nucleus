import Synchronization

private final class WeakHost<Host: AnyObject>: @unchecked Sendable {
    weak var value: Host?

    init(_ value: Host) {
        self.value = value
    }
}

private struct WeakHostRegistryState<Host: AnyObject>: @unchecked Sendable {
    var nextID: UInt64 = 1
    var hosts: [UInt64: WeakHost<Host>] = [:]
}

package final class WeakHostRegistry<Host: AnyObject>: Sendable {
    private let state = Mutex(WeakHostRegistryState<Host>())

    package init() {}

    package func register(_ host: Host) -> UInt64 {
        state.withLock {
            precondition($0.nextID != 0, "host ID space exhausted")
            let id = $0.nextID
            $0.nextID &+= 1
            $0.hosts[id] = WeakHost(host)
            return id
        }
    }

    package func lookup(_ id: UInt64) -> Host? {
        guard id != 0 else { return nil }
        return state.withLock {
            guard let entry = $0.hosts[id] else { return nil }
            guard let host = entry.value else {
                $0.hosts.removeValue(forKey: id)
                return nil
            }
            return host
        }
    }

    package func unregister(_ id: UInt64, host: Host) {
        guard id != 0 else { return }
        state.withLock {
            guard $0.hosts[id]?.value === host else { return }
            $0.hosts.removeValue(forKey: id)
        }
    }
}

package struct OwnerThreadGuard: Sendable {
    private let ownerID: Int64
    private let currentID: @Sendable () -> Int64
    private let reportViolation: @Sendable (StaticString) -> Void

    package init(
        currentID: @escaping @Sendable () -> Int64,
        reportViolation: @escaping @Sendable (StaticString) -> Void
    ) {
        ownerID = currentID()
        self.currentID = currentID
        self.reportViolation = reportViolation
    }

    package func accepts(_ operation: StaticString) -> Bool {
        guard currentID() == ownerID else {
            reportViolation(operation)
            return false
        }
        return true
    }
}

package struct NativeSurfaceSlot<Handle> {
    package private(set) var handle: Handle?

    package init() {
        handle = nil
    }

    package mutating func adopt(_ handle: Handle) -> Handle? {
        let previous = self.handle
        self.handle = handle
        return previous
    }

    package mutating func detach() -> Handle? {
        defer { handle = nil }
        return handle
    }
}
