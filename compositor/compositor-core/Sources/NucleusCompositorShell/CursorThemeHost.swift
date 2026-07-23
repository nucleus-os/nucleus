public import NucleusCompositorServer

@MainActor
public final class CursorThemeService {
    private unowned let server: NucleusCompositorServer
    private let theme: CursorTheme

    public init(
        server: NucleusCompositorServer,
        theme: CursorTheme = CursorTheme()
    ) {
        self.server = server
        self.theme = theme
    }

    public func applyDefault() {
        applyNamed("default")
    }

    public func applyNamed(_ name: String) {
        let resolved = name.isEmpty ? "default" : name
        let cursor = server.cursor
        guard resolved != cursor.themeName else { return }
        let image = theme.load(name: resolved, size: 24)
        cursor.applyTheme(
            name: resolved,
            pixels: [UInt8](image.pixels),
            width: image.width,
            height: image.height,
            hotSpotX: Int32(bitPattern: image.hotSpotX),
            hotSpotY: Int32(bitPattern: image.hotSpotY))
    }
}
