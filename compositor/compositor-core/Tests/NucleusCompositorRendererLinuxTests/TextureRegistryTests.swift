import Testing
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer

// allocator + atlas + texture registry (handle/refcount/content-revision), all
// hardware-independent via raster-surface snapshots; plus a best-effort check
// that the façade backend-texture wrap fails closed on a null descriptor (the GPU
// stages assert nothing hardware-conditional).
@Suite struct TextureRegistryTests {
    @Test func guillotineAllocator() {
        // GuillotineAllocator (mirrors the Zig allocate/free test).
        var ga = GuillotineAllocator(width: 64, height: 64)
        guard let a = ga.allocate(w: 32, h: 32) else { #expect(Bool(false), "ga-alloc-a"); return }
        #expect(a.x == 0 && a.y == 0, "ga-alloc-a-origin")
        #expect(ga.usedArea == 32 * 32, "ga-used-after-a")
        guard let b = ga.allocate(w: 32, h: 32) else { #expect(Bool(false), "ga-alloc-b"); return }
        #expect(b.x != a.x || b.y != a.y, "ga-alloc-b-distinct")
        #expect(ga.usedArea == 2 * 32 * 32, "ga-used-after-b")
        // Free reclaims area; a same-size alloc fits again.
        ga.free(x: a.x, y: a.y, w: 32, h: 32)
        #expect(ga.usedArea == 32 * 32, "ga-used-after-free")
        #expect(ga.allocate(w: 32, h: 32) != nil, "ga-realloc-after-free")
        // Oversized requests fail.
        var gFull = GuillotineAllocator(width: 16, height: 16)
        #expect(gFull.allocate(w: 32, h: 8) == nil, "ga-oversize-fails")
    }

    @Test func textureAtlas() {
        // TextureAtlas: packs into pages, spills to new page when full.
        var atlas = TextureAtlas(pageSize: 64)
        let first = atlas.allocate(w: 64, h: 64)
        #expect(first?.page == 0, "atlas-first-page")
        #expect(atlas.pageCount == 1, "atlas-one-page")
        // The page is full; the next allocation opens a second page.
        let second = atlas.allocate(w: 32, h: 32)
        #expect(second?.page == 1, "atlas-second-page")
        #expect(atlas.pageCount == 2, "atlas-two-pages")
        // Too large for any page → rejected.
        #expect(atlas.allocate(w: 128, h: 16) == nil, "atlas-oversize-rejected")
        // Freeing the full first page lets a new allocation reuse page 0.
        if let first { atlas.free(first) }
        #expect(atlas.allocate(w: 16, h: 16)?.page == 0, "atlas-reuse-after-free")
    }

    @Test func textureRegistry() {
        // TextureRegistry: handles, content-revision, and refcount.
        let registry = TextureRegistry()
        #expect(registry.count == 0, "registry-empty")
        let surface = nucleus.skia.makeRasterSurface(2, 2)
        let image = surface.snapshotImage()
        #expect(image.isValid())
        let h1 = registry.allocRendererHandle()
        let rendererKey = TextureRegistryKey.renderer(h1)
        registry.register(
            key: rendererKey, image: image,
            width: 2, height: 2, contentRevision: 1)
        #expect(h1 != 0, "registry-handle-nonzero")
        #expect(registry.count == 1, "registry-count-after-upload")
        // resolve() returns the C++ nucleus.skia.Image (unreachable via cross-module
        // @testable); size() is a Swift-typed proxy for the same entry lookup.
        #expect(registry.size(rendererKey) != nil, "registry-present")
        #expect(
            registry.size(rendererKey)?.width == 2
                && registry.size(rendererKey)?.height == 2,
            "registry-size")

        // Content revision gates re-upload.
        #expect(!registry.needsUpdate(rendererKey, revision: 1), "registry-revision-current")
        #expect(registry.needsUpdate(rendererKey, revision: 2), "registry-revision-stale")
        #expect(
            registry.needsUpdate(.renderer(999), revision: 1),
            "registry-unknown-needs-update")

        // Refcount lifecycle: retain → 2 releases to evict.
        registry.retain(rendererKey)
        #expect(!registry.release(rendererKey), "registry-release-still-held")
        #expect(registry.size(rendererKey) != nil, "registry-present-after-partial-release")
        #expect(registry.release(rendererKey), "registry-release-evicts")
        #expect(registry.size(rendererKey) == nil, "registry-evicted")
        #expect(registry.count == 0, "registry-count-after-evict")
        #expect(!registry.release(rendererKey), "registry-release-unknown")

        // Handles are distinct + non-zero across registrations.
        let h2 = registry.allocRendererHandle()
        let h3 = registry.allocRendererHandle()
        registry.register(
            key: .renderer(h2), image: image,
            width: 2, height: 2, contentRevision: 1)
        registry.register(
            key: .renderer(h3), image: image,
            width: 2, height: 2, contentRevision: 1)
        #expect(h2 != 0 && h3 != 0 && h2 != h3, "registry-distinct-handles")

        // Client IDs are an independent namespace. A client surface whose ID
        // equals a live renderer handle must coexist without replacing it.
        registry.register(
            key: .clientSurface(h2), image: image,
            width: 3840, height: 28, contentRevision: 7)
        #expect(registry.count == 3, "registry-namespaces-coexist")
        #expect(registry.size(.renderer(h2))?.height == 2)
        #expect(registry.size(.clientSurface(h2))?.height == 28)
        #expect(registry.release(.clientSurface(h2)))
        #expect(registry.size(.renderer(h2)) != nil)
    }

    // Best-effort: exercise the façade backend-texture wrap on a real Graphite
    // context where one is available. Hardware-gated, so it asserts nothing.
    @Test(.disabled("requires a live GPU/Vulkan device")) func backendImageWrapBestEffort() {
        let registry = TextureRegistry()
        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "TextureRegistryTests",
            contract: contract, enableValidation: false
        ) else { return }
        guard let selection = DeviceOwner.selectPhysicalDevice(
            instance: instance.handle, dispatch: instance.dispatch, contract: contract
        ) else { return }
        guard let device = DeviceOwner.create(
            selection: selection, instanceDispatch: instance.dispatch,
            contract: contract
        ) else { return }
        guard let queue = device.queue(family: selection.graphicsQueueFamily) else { return }

        withCStringArray(contract.deviceExtensions) { extPtr, extCount in
            var desc = nucleus.skia.VulkanContextDescriptor()
            desc.instance = UnsafeMutableRawPointer(instance.handle)
            desc.physicalDevice = UnsafeMutableRawPointer(selection.physicalDevice)
            desc.device = UnsafeMutableRawPointer(device.handle)
            desc.queue = UnsafeMutableRawPointer(queue)
            desc.graphicsQueueIndex = selection.graphicsQueueFamily
            desc.maxApiVersion = VkRequirements.minimumApiVersion.raw
            desc.deviceExtensions = extPtr
            desc.deviceExtensionCount = extCount

            let context = nucleus.skia.makeGraphiteVulkanContext(desc)
            guard context.isValid() else { return }
            let recorder = context.makeRecorder()
            guard recorder.isValid() else { return }

            // A descriptor with no image wraps to an invalid image (fail-closed).
            var nullDesc = nucleus.skia.VulkanImageDescriptor()
            nullDesc.width = 64
            nullDesc.height = 64
            _ = registry.wrapBackendImage(recorder: recorder, descriptor: nullDesc)
        }
    }
}
