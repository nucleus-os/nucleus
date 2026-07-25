import Dispatch
import Synchronization
import Testing
@testable import NucleusAndroidHostLifecycle

private final class HostProbe: @unchecked Sendable {}

@Suite(.serialized)
struct HostLifecycleTests {
    @Test func registryRejectsInvalidAndClosedIDsWithoutReuse() {
        let registry = WeakHostRegistry<HostProbe>()
        var first: HostProbe? = HostProbe()
        let firstID = registry.register(first!)

        #expect(firstID != 0)
        #expect(registry.lookup(0) == nil)
        #expect(registry.lookup(UInt64.max) == nil)
        #expect(registry.lookup(firstID) === first)

        registry.unregister(firstID, host: first!)
        #expect(registry.lookup(firstID) == nil)
        first = nil

        let second = HostProbe()
        let secondID = registry.register(second)
        #expect(secondID > firstID)
        #expect(registry.lookup(firstID) == nil)
    }

    @Test func lookupRetainsHostAcrossConcurrentClose() async {
        let registry = WeakHostRegistry<HostProbe>()
        var owner: HostProbe? = HostProbe()
        weak let weakHost = owner
        let id = registry.register(owner!)
        let retained = registry.lookup(id)

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                registry.unregister(id, host: retained!)
                continuation.resume()
            }
        }
        owner = nil

        #expect(registry.lookup(id) == nil)
        #expect(weakHost != nil)
        withExtendedLifetime(retained) {}
    }

    @Test func ownerThreadGuardRejectsWithoutRunningMutation() async {
        let currentID = Mutex<Int64>(41)
        let violations = Mutex(0)
        let mutations = Mutex(0)
        let guardrail = OwnerThreadGuard(
            currentID: { currentID.withLock { $0 } },
            reportViolation: { _ in violations.withLock { $0 += 1 } })

        currentID.withLock { $0 = 42 }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                if guardrail.accepts("test mutation") {
                    mutations.withLock { $0 += 1 }
                }
                continuation.resume()
            }
        }

        #expect(mutations.withLock { $0 } == 0)
        #expect(violations.withLock { $0 } == 1)
    }

    @Test func surfaceAttachReplaceDetachAndShutdownBalanceOwnership() {
        var slot = NativeSurfaceSlot<Int>()
        var acquired = 0
        var released = 0

        func acquire(_ value: Int) -> Int {
            acquired += 1
            return value
        }
        func release(_ value: Int?) {
            if value != nil { released += 1 }
        }

        release(slot.adopt(acquire(1)))
        release(slot.adopt(acquire(2)))
        release(slot.detach())
        release(slot.detach())
        release(slot.adopt(acquire(3)))
        release(slot.detach())

        #expect(acquired == 3)
        #expect(released == 3)
        #expect(slot.handle == nil)
    }
}
