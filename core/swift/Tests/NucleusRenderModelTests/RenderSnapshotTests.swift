@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderSnapshotTests {
    static func publish(
        _ service: SnapshotService,
        _ discriminator: UInt64
    ) -> (handle: SnapshotHandle, size: Bounds) {
        let id = 0x1000 + discriminator * 0x100
        let size = Bounds(w: Float(discriminator + 10), h: Float(discriminator + 20))
        let handle = service.registerTextureHandle(TextureHandle(raw: id), size: size)
        return (handle, size)
    }

    @Test func renderSnapshot() {
        let service = SnapshotService()

        let fromLayer = Self.publish(service, 7)
        let fromRoot = Self.publish(service, 109)
        let fromIosurface = Self.publish(service, 211)
        #expect(service.liveCount == 3)
        #expect(!fromLayer.handle.isNone && !fromRoot.handle.isNone && !fromIosurface.handle.isNone,
              "routing-handles-nonzero")
        #expect(fromLayer.size.w == 17, "layer-size")
        #expect(fromRoot.size.w == 119, "root-size")
        #expect(fromIosurface.size.w == 221, "iosurface-size")

        // Handles are distinct + monotonic.
        #expect(fromLayer.handle != fromRoot.handle && fromRoot.handle != fromIosurface.handle,
              "handles-distinct")

        // resolve returns the entry; none-handle resolves nil.
        let entry = service.resolve(fromLayer.handle)
        #expect(entry?.size.w == 17 && entry?.refcount == 1, "resolve-entry")
        #expect(service.resolve(.none) == nil, "resolve-none-nil")

        // retain/release refcounting: release is nil until the final ref.
        service.retain(fromLayer.handle)
        #expect(service.resolve(fromLayer.handle)?.refcount == 2, "retain-bumps")
        #expect(service.release(fromLayer.handle) == nil, "release-not-final")
        #expect(service.resolve(fromLayer.handle)?.refcount == 1, "release-decrements")
        // Final release returns the texture handle + drops the entry.
        let released = service.release(fromLayer.handle)
        #expect(released == TextureHandle(raw: 0x1000 + 7 * 0x100), "release-final-returns-texture")
        #expect(service.resolve(fromLayer.handle) == nil, "release-final-drops-entry")
        #expect(service.liveCount == 2)

        // none-handle retain/release are inert.
        service.retain(.none)
        #expect(service.release(.none) == nil, "release-none-nil")

        // Provenance round-trips.
        let h = service.registerTextureHandle(TextureHandle(raw: 0x9000), size: Bounds(w: 10, h: 20),
                                              provenance: .liveIosurface(IOSurfaceID(raw: 55)))
        #expect(service.liveCount == 3)
        #expect(service.resolve(h)?.provenance == .liveIosurface(IOSurfaceID(raw: 55)), "provenance-roundtrip")
        #expect(service.resolve(h)?.texture == TextureHandle(raw: 0x9000), "provenance-texture")

        // releaseAll routes every live texture through the releaser + clears.
        var releasedTextures: [TextureHandle] = []
        service.releaseAll { releasedTextures.append($0) }
        // Still-live entries at this point: fromRoot, fromIosurface, h.
        #expect(releasedTextures.count == 3, "release-all-count")
        #expect(service.resolve(h) == nil && service.resolve(fromRoot.handle) == nil, "release-all-clears")
        #expect(service.liveCount == 0)
    }
}
