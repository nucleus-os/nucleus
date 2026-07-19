/// A cursor shape, as `wp_cursor_shape_device_v1` numbers them.
///
/// The shell's own vocabulary rather than NucleusUI's: `NucleusShellWayland` sits
/// below the UI layer and must not import it. The runtime maps `Cursor` onto this
/// at the one place the two vocabularies meet, which is the same seam the battery
/// widget and UPower already sit either side of.
public enum ShellCursorShape: UInt32, Sendable, Equatable {
    // `default` is a keyword; the trailing underscore is the cost of matching
    // the protocol's own naming.
    case default_ = 1
    case contextMenu = 2
    case help = 3
    case pointer = 4
    case progress = 5
    case wait = 6
    case cell = 7
    case crosshair = 8
    case text = 9
    case alias = 11
    case copy = 12
    case move = 13
    case noDrop = 14
    case notAllowed = 15
    case grab = 16
    case grabbing = 17
    case ewResize = 26
    case nsResize = 27
    case neswResize = 28
    case nwseResize = 29
    case allScroll = 32
    case zoomIn = 33
    case zoomOut = 34
}
