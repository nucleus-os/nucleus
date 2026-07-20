@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderRuntimeEffectStoreTests {
    private static let programA = "half4 main(float2 p) { return half4(1); }"
    private static let programB = "half4 main(float2 p) { return half4(0); }"

    @Test func registerRetainReleaseRoundTrip() {
        let store = RuntimeEffectStore()
        #expect(store.count == 0, "initial-empty")

        let h = store.register(RuntimeEffectSource(sksl: Self.programA))
        #expect(h != 0, "register-nonzero")
        #expect(store.count == 1, "register-count")
        #expect(store.source(h)?.sksl == Self.programA, "register-roundtrip")

        let other = store.register(RuntimeEffectSource(sksl: Self.programB))
        #expect(other != h, "distinct-source-distinct-handle")
        #expect(store.count == 2, "second-count")

        store.retain(h)
        store.release(h)
        #expect(store.source(h) != nil, "retain-keeps")
        store.release(h)
        #expect(store.source(h) == nil, "release-evicts")
        #expect(store.count == 1, "evict-count")

        store.release(9999)
        #expect(store.count == 1, "unknown-release-noop")
    }

    /// The shell's effect set is small and fixed but registered repeatedly as
    /// views come and go. Registering the same program twice must share one
    /// handle, or the renderer compiles the same SkSL once per view.
    @Test func identicalSourcesShareOneHandle() {
        let store = RuntimeEffectStore()
        let first = store.register(RuntimeEffectSource(sksl: Self.programA))
        let second = store.register(RuntimeEffectSource(sksl: Self.programA))
        #expect(first == second, "identical sources dedupe")
        #expect(store.count == 1, "dedupe does not add an entry")

        // Deduping bumped the refcount, so one release must not evict.
        store.release(first)
        #expect(store.source(first) != nil, "dedupe bumped the refcount")
        store.release(first)
        #expect(store.source(first) == nil, "second release evicts")
    }

    /// The renderer caches compiled programs keyed by handle and drops them on
    /// eviction; handles are monotonic and never reused, so without this the
    /// compiled effect would persist until shutdown.
    @Test func evictionQueuesOnceWhenTheLastReferenceDrops() {
        let store = RuntimeEffectStore()

        let h = store.register(RuntimeEffectSource(sksl: Self.programA))
        store.retain(h)
        store.release(h)
        #expect(
            store.takeEvictedHandles().isEmpty,
            "no eviction while a reference remains")

        store.release(h)
        #expect(
            store.takeEvictedHandles() == [h],
            "eviction queues once on the last release")
        #expect(store.takeEvictedHandles().isEmpty, "evictions drain once")
    }

    /// A handle freed and a later registration of the same source must not
    /// silently resurrect the old handle value.
    @Test func handlesAreNotReusedAfterEviction() {
        let store = RuntimeEffectStore()
        let first = store.register(RuntimeEffectSource(sksl: Self.programA))
        store.release(first)
        let second = store.register(RuntimeEffectSource(sksl: Self.programA))
        #expect(second != first, "a fresh handle is minted after eviction")
    }
}
