/// A pointer shape.
///
/// The set is the Wayland cursor-shape vocabulary, which is also the subset of
/// `NSCursor` a shell actually uses. These are names, not images: the shell hands
/// the resolved cursor to the compositor, which owns the theme and the pixels.
public enum Cursor: String, Sendable, Equatable, CaseIterable {
    case arrow = "default"
    case pointingHand = "pointer"
    case text
    case crosshair
    case notAllowed = "not-allowed"
    case grab
    case grabbing
    case resizeLeftRight = "ew-resize"
    case resizeUpDown = "ns-resize"
    case resizeNorthWestSouthEast = "nwse-resize"
    case resizeNorthEastSouthWest = "nesw-resize"
    case wait
    case help

    /// The name to hand a `wp_cursor_shape_device_v1` or an X cursor theme.
    public var shapeName: String { rawValue }
}
