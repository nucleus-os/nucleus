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

public final class WeakHostRegistry<Host: AnyObject>: Sendable {
    private let state = Mutex(WeakHostRegistryState<Host>())

    public init() {}

    public func register(_ host: Host) -> UInt64 {
        state.withLock {
            precondition($0.nextID != 0, "host ID space exhausted")
            let id = $0.nextID
            $0.nextID &+= 1
            $0.hosts[id] = WeakHost(host)
            return id
        }
    }

    public func lookup(_ id: UInt64) -> Host? {
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

    public func unregister(_ id: UInt64, host: Host) {
        guard id != 0 else { return }
        state.withLock {
            guard $0.hosts[id]?.value === host else { return }
            $0.hosts.removeValue(forKey: id)
        }
    }
}

public struct OwnerThreadGuard: Sendable {
    private let ownerID: Int64
    private let currentID: @Sendable () -> Int64
    private let reportViolation: @Sendable (StaticString) -> Void

    public init(
        currentID: @escaping @Sendable () -> Int64,
        reportViolation: @escaping @Sendable (StaticString) -> Void
    ) {
        ownerID = currentID()
        self.currentID = currentID
        self.reportViolation = reportViolation
    }

    public func accepts(_ operation: StaticString) -> Bool {
        guard currentID() == ownerID else {
            reportViolation(operation)
            return false
        }
        return true
    }
}

public struct NativeSurfaceSlot<Handle> {
    public private(set) var handle: Handle?

    public init() {
        handle = nil
    }

    public mutating func adopt(_ handle: Handle) -> Handle? {
        let previous = self.handle
        self.handle = handle
        return previous
    }

    public mutating func detach() -> Handle? {
        defer { handle = nil }
        return handle
    }
}
