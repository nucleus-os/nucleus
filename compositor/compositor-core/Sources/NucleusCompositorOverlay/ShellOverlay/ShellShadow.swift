import NucleusUI
import NucleusUIEmbedder

/// Default macOS-style drop shadows for shell-overlay surfaces. Tuned to
/// approximate the visual weight of a `NSPanel` / `NSPopover` shadow on
/// a key window. The view publisher attaches these to the appropriate
/// backing layer; the renderer rasterizes them via the existing decoration
/// cache.
enum ShellShadow {
    /// Visible corner radius shared by the notification card and the
    /// hotkey overlay backdrop. Keeps shadow shape in sync with the
    /// rounded backdrop child layer; if you change one of those view
    /// metrics, change this too.
    static let popoverCornerRadius: Double = 18

    /// Notification banner — soft downward shadow under a popover-style
    /// rounded rect. Slightly tighter than a window shadow because the
    /// banner sits closer to the surface visually.
    static let notification = Shadow(
        offsetX: 0,
        offsetY: 12,
        blurRadius: 28,
        cornerRadius: popoverCornerRadius,
        opacity: 0.28,
        color: Color(0, 0, 0, 1)
    )

    /// Hotkey overlay — wider, softer shadow because the panel is large
    /// and centered on screen, like a Quick Look or Mission Control HUD.
    static let hotkeyOverlay = Shadow(
        offsetX: 0,
        offsetY: 20,
        blurRadius: 48,
        cornerRadius: popoverCornerRadius,
        opacity: 0.35,
        color: Color(0, 0, 0, 1)
    )

    /// Window / application menu — a tighter `NSMenu`-style drop shadow under a
    /// small-radius rounded rect. Its corner radius matches `menuCornerRadius`.
    static let menuCornerRadius: Double = 6

    static let menu = Shadow(
        offsetX: 0,
        offsetY: 8,
        blurRadius: 22,
        cornerRadius: menuCornerRadius,
        opacity: 0.30,
        color: Color(0, 0, 0, 1)
    )
}
