package import NucleusCompositorServer
import NucleusThemeAssetIO

@MainActor
package final class ServerCursorThemeService {
    private struct Key: Hashable, Sendable {
        var name: String
        var size: UInt32
    }

    private unowned let server: NucleusCompositorServer
    private let fallback: XCursorImage
    private let io: BoundedThemeAssetIO<Key, XCursorImage>
    private var requestGeneration: UInt64 = 0

    package init(
        server: NucleusCompositorServer,
        loader: CursorImageLoader = CursorImageLoader()
    ) {
        self.server = server
        fallback = loader.defaultCursor()
        io = Self.makeIO { key in
            loader.load(name: key.name, size: key.size)
        }
    }

    init(
        server: NucleusCompositorServer,
        fallback: XCursorImage,
        resolver: @escaping @Sendable (String, UInt32) -> XCursorImage
    ) {
        self.server = server
        self.fallback = fallback
        io = Self.makeIO { key in resolver(key.name, key.size) }
    }

    private static func makeIO(
        resolver: @escaping @Sendable (Key) -> XCursorImage
    ) -> BoundedThemeAssetIO<Key, XCursorImage> {
        BoundedThemeAssetIO(
            label: "dev.nucleus.theme-cursors",
            maximumPending: 256,
            maximumConcurrent: 2,
            maximumCompletedEntries: 256,
            maximumCompletedCost: 16 * 1_024 * 1_024,
            cost: { $0.pixels.count },
            processor: resolver)
    }

    package func applyDefault() {
        applyNamed("default")
    }

    package func applyNamed(_ name: String) {
        let resolved = name.isEmpty ? "default" : name
        guard resolved != server.cursor.themeName else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        apply(fallback, name: resolved)
        Task { [weak self] in
            guard let self,
                let image = await io.resolve(
                    Key(name: resolved, size: 24)),
                requestGeneration == generation
            else { return }
            apply(image, name: resolved)
        }
    }

    private func apply(_ image: XCursorImage, name: String) {
        server.cursor.applyTheme(
            name: name,
            pixels: [UInt8](image.pixels),
            width: image.width,
            height: image.height,
            hotSpotX: Int32(bitPattern: image.hotSpotX),
            hotSpotY: Int32(bitPattern: image.hotSpotY))
    }
}
