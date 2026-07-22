import Testing
import WaylandServerC
@testable import WaylandServer

@Suite
struct WaylandResourceOwnershipTests {
    private final class Owner {}

    @Test
    func failedNativeCreationDoesNotConsumeTheSwiftOwner() throws {
        var owner: Owner? = Owner()
        weak let observedOwner = owner

        let resource = WaylandResource.create(
            client: OpaquePointer(bitPattern: 1)!,
            interface: nil,
            version: 1,
            id: 1,
            vtable: nil,
            owner: owner!,
            using: { _, _, _, _ in nil })

        #expect(resource == nil)
        #expect(observedOwner === owner)
        owner = nil
        #expect(observedOwner == nil)
    }
}
