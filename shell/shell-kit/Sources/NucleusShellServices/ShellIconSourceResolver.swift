import NucleusThemeAssetIO
package import NucleusUI
import Synchronization

/// Bounded icon lookup whose filesystem work runs only on ThemeAssetIO workers.
package final class ShellIconSourceResolver: Sendable {
    private struct Key: Hashable, Sendable {
        var name: String
        var theme: String
        var pixelSize: UInt32
        var generation: UInt64
    }

    private struct Resolution: Sendable {
        var path: String?
    }

    private let io: BoundedThemeAssetIO<Key, Resolution>
    private let generation = Mutex<UInt64>(0)

    package init(themeName: String = "hicolor", roots: [String]? = nil) {
        let capturedRoots = roots ?? IconThemeResolver.defaultRoots()
        io = BoundedThemeAssetIO(
            label: "dev.nucleus.theme-icons",
            maximumPending: 256,
            maximumConcurrent: 2,
            maximumCompletedEntries: 4_096
        ) { key in
            Resolution(
                path: IconThemeResolver(
                    themeName: key.theme.isEmpty ? themeName : key.theme,
                    roots: capturedRoots
                )
                .resolve(
                    key.name,
                    size: max(1, Int(clamping: key.pixelSize))))
        }
    }

    package var imageSourceResolver: ImageSourceResolver {
        let owner = self
        return ImageSourceResolver { query in
            guard case .icon(let name, let theme) = query.source else {
                return nil
            }
            return await owner.io.resolve(
                Key(
                    name: name,
                    theme: theme,
                    pixelSize: max(
                        query.targetPixelWidth,
                        query.targetPixelHeight),
                    generation: owner.generation.withLock { $0 }))?.path
        }
    }

    package func invalidate() async -> UInt64 {
        let next = generation.withLock { value in
            value &+= 1
            return value
        }
        await io.invalidateAll()
        return next
    }
}
