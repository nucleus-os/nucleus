public import NucleusUI

/// Serializes XDG filesystem resolution off the UI actor and projects it into
/// the portable retained image request seam.
public actor ShellIconSourceResolver {
    private let resolver: IconThemeResolver

    public init(
        themeName: String = "hicolor",
        roots: [String]? = nil
    ) {
        resolver = IconThemeResolver(
            themeName: themeName,
            roots: roots)
    }

    public nonisolated var imageSourceResolver: ImageSourceResolver {
        let owner = self
        return ImageSourceResolver { query in
            guard case .icon(let name, let theme) = query.source else {
                return nil
            }
            return await owner.resolve(
                name: name,
                theme: theme,
                pixelSize: max(
                    query.targetPixelWidth,
                    query.targetPixelHeight))
        }
    }

    public func invalidate() -> UInt64 {
        resolver.invalidate()
        return resolver.generation
    }

    private func resolve(
        name: String,
        theme: String,
        pixelSize: UInt32
    ) -> String? {
        if resolver.themeName != theme {
            resolver.themeName = theme
        }
        return resolver.resolve(
            name,
            size: max(1, Int(clamping: pixelSize)))
    }
}
