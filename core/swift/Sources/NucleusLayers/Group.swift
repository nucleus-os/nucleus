@MainActor
public enum Group {
    private static var nextID: UInt64 = 1

    public static func atomic(hosts: [Context], _ body: () throws -> Void) rethrows {
        let activeGroup = ActiveGroup(id: allocateGroupID())
        let previous = hosts.map { ($0, $0.activeGroup) }
        for host in hosts {
            host.activeGroup = activeGroup
        }
        defer {
            for (host, previousGroup) in previous {
                host.activeGroup = previousGroup
            }
        }
        try body()
    }

    private static func allocateGroupID() -> UInt64 {
        let current = nextID
        nextID &+= 1
        if nextID == 0 {
            nextID = 1
        }
        return current
    }
}
