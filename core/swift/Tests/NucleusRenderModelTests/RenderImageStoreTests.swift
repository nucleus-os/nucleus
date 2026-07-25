import Testing
@testable import NucleusRenderModel

@Suite struct RenderImageStoreTests {
    private func source(_ name: String) -> ImageSource {
        ImageSource(
            path: name,
            maxWidth: 32,
            maxHeight: 32)
    }

    @Test func ordinarySourceChangeAllocatesANewHandle() {
        let store = ImageStore()
        let first = store.register(source("first"))
        let second = store.register(source("second"))

        #expect(first != second)
        #expect(store.source(first) == source("first"))
        #expect(store.source(second) == source("second"))
    }

    @Test func retryQueuesAnExplicitGenerationMutation() {
        let store = ImageStore()
        let handle = store.register(source("image"))

        #expect(store.retry(handle))
        #expect(
            store.takeMutations()
                == [.retry(handle: handle)])
        #expect(store.takeMutations().isEmpty)
    }

    @Test func replacementPreservesHandleAndPublishesNewSource() {
        let store = ImageStore()
        let handle = store.register(source("old"))
        let replacement = source("new")

        #expect(store.replace(handle, with: replacement))
        #expect(store.source(handle) == replacement)
        #expect(
            store.takeMutations()
                == [.replace(
                    handle: handle,
                    source: replacement)])
    }

    @Test func replacementCannotStealAnotherLiveIdentity() {
        let store = ImageStore()
        let first = store.register(source("first"))
        let second = store.register(source("second"))

        #expect(!store.replace(first, with: source("second")))
        #expect(store.source(first) == source("first"))
        #expect(store.source(second) == source("second"))
        #expect(store.takeMutations().isEmpty)
    }

    @Test func finalReleaseQueuesEvictionExactlyOnce() {
        let store = ImageStore()
        let handle = store.register(source("image"))

        store.release(handle)
        store.release(handle)
        #expect(
            store.takeMutations()
                == [.evict(handle: handle)])
        #expect(store.takeMutations().isEmpty)
    }
}
