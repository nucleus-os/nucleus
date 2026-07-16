@_spi(NucleusCompositor) import NucleusUI

/// One row of a `Menu`. `actionID` is caller-defined: a window-verb tag for the
/// window menu, a `com.canonical.dbusmenu` item id for an application pulldown.
/// A separator carries no action and is never highlighted. `submenu`, when
/// present, renders a trailing arrow; opening it is wired in a later step.
public struct MenuItem: Sendable, Equatable {
    public var label: String
    public var actionID: Int
    public var isEnabled: Bool
    public var isSeparator: Bool
    public var submenu: [MenuItem]?

    public init(
        label: String,
        actionID: Int,
        isEnabled: Bool = true,
        isSeparator: Bool = false,
        submenu: [MenuItem]? = nil
    ) {
        self.label = label
        self.actionID = actionID
        self.isEnabled = isEnabled
        self.isSeparator = isSeparator
        self.submenu = submenu
    }

    public static func separator() -> MenuItem {
        MenuItem(label: "", actionID: -1, isEnabled: false, isSeparator: true)
    }
}

/// A menu model. The single source of truth lives in the compositor; this is the
/// shape it pushes to the renderer. The window menu and every application-menu
/// pulldown share this type and the `ShellOverlayMenuView` that renders it.
public struct Menu: Sendable, Equatable {
    public var items: [MenuItem]

    public init(items: [MenuItem]) {
        self.items = items
    }
}

/// The window-menu verb tags, used as `MenuItem.actionID`. The selection callback
/// reports the chosen tag back across the overlay boundary to the compositor,
/// which dispatches the matching window verb. Mirrors the `NSWindow` window-menu
/// commands (close / miniaturize / zoom / toggle-full-screen) in Wayland terms.
public enum WindowMenuVerb: Int, Sendable {
    case close = 0
    case minimize = 1
    case zoom = 2
    case toggleFullScreen = 3
    case move = 4
    case resize = 5
}

/// Which window verbs the window menu enables, derived compositor-side from the
/// window's style mask (its standard-button set) and crossed into the overlay as
/// a single bitfield. An unset bit leaves the item present but disabled, matching
/// the AppKit window menu (a non-closable window still shows a dimmed Close).
public struct WindowMenuCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let closable = WindowMenuCapabilities(rawValue: 1 << 0)
    public static let minimizable = WindowMenuCapabilities(rawValue: 1 << 1)
    public static let zoomable = WindowMenuCapabilities(rawValue: 1 << 2)
    public static let fullScreenable = WindowMenuCapabilities(rawValue: 1 << 3)
    public static let movable = WindowMenuCapabilities(rawValue: 1 << 4)
    public static let resizable = WindowMenuCapabilities(rawValue: 1 << 5)
}

public extension Menu {
    /// The standard per-window menu, shaped after the macOS window menu with the
    /// X11/GTK interactive Move and Resize verbs grouped in: Minimize, Zoom, a
    /// separator, Move, Resize, Enter Full Screen, a separator, then Close. Every
    /// item is always present; an item is `isEnabled` only when its capability bit
    /// is set so the menu reads the same across windows and only the dimming
    /// changes. Move and Resize begin a compositor-owned interactive grab that the
    /// next click commits.
    static func windowMenu(capabilities: UInt32) -> Menu {
        let caps = WindowMenuCapabilities(rawValue: capabilities)
        return Menu(items: [
            MenuItem(
                label: "Minimize",
                actionID: WindowMenuVerb.minimize.rawValue,
                isEnabled: caps.contains(.minimizable)
            ),
            MenuItem(
                label: "Zoom",
                actionID: WindowMenuVerb.zoom.rawValue,
                isEnabled: caps.contains(.zoomable)
            ),
            .separator(),
            MenuItem(
                label: "Move",
                actionID: WindowMenuVerb.move.rawValue,
                isEnabled: caps.contains(.movable)
            ),
            MenuItem(
                label: "Resize",
                actionID: WindowMenuVerb.resize.rawValue,
                isEnabled: caps.contains(.resizable)
            ),
            MenuItem(
                label: "Enter Full Screen",
                actionID: WindowMenuVerb.toggleFullScreen.rawValue,
                isEnabled: caps.contains(.fullScreenable)
            ),
            .separator(),
            MenuItem(
                label: "Close",
                actionID: WindowMenuVerb.close.rawValue,
                isEnabled: caps.contains(.closable)
            ),
        ])
    }
}

/// Metrics for the native menu panel, tuned to an `NSMenu`.
private enum MenuMetrics {
    static let fontSize: Float = 13
    static let rowHeight: Double = 22
    static let separatorHeight: Double = 11
    static let leadingInset: Double = 14
    static let trailingInset: Double = 14
    static let arrowWidth: Double = 14
    static let verticalPadding: Double = 5
    static let minWidth: Double = 140
    static let maxWidth: Double = 360
    static let highlightInsetX: Double = 5
    static let cornerRadius: Double = ShellShadow.menuCornerRadius
}

/// The shared native menu renderer: a rounded, blurred panel of rows over a drop
/// shadow. Rows highlight on press (and, once the overlay routes hover, on
/// pointer-over via `highlightRow(at:)`); activating a row reports its
/// `actionID` to `setSelectHandler`. Separators draw a hairline and never
/// participate in hit-testing. The panel sizes to its widest row through
/// `preferredSize`; the host positions it at the requested anchor.
final class ShellOverlayMenuView: View, ~Sendable {
    private let backgroundEffectView: VisualEffectView
    private let menu: Menu
    private var rowViews: [MenuRowView] = []
    private var separatorViews: [View] = []
    /// The selected row as an index into `rowViews`, shared by pointer hover and
    /// keyboard navigation so the two never disagree. Nil means no selection.
    private var highlightedIndex: Int?

    /// The panel's top inset (padding above the first row). A submenu panel is
    /// raised by this so its first row aligns with the parent row that spawned it.
    static var topPadding: Double { MenuMetrics.verticalPadding }

    init(menu: Menu) {
        self.menu = menu
        self.backgroundEffectView = VisualEffectView(
            material: .menu,
            state: .active,
            cornerRadius: MenuMetrics.cornerRadius
        )
        super.init()
        cornerRadius = MenuMetrics.cornerRadius
        shadow = ShellShadow.menu
        addSubview(backgroundEffectView)
        for item in menu.items {
            if item.isSeparator {
                let separator = View()
                addSubview(separator)
                separatorViews.append(separator)
            } else {
                let row = MenuRowView(item: item)
                addSubview(row)
                rowViews.append(row)
            }
        }
        isAccessibilityElement = true
        accessibilityRole = .window
        accessibilityLabel = "Menu"
        accessibilityChildren = rowViews
    }

    /// The index (into the visible rows) of the enabled, non-separator row under a
    /// panel-local point, or nil if none. The host works in indices so a row maps
    /// to its `MenuItem` (its token and submenu) and its frame (to anchor a child
    /// submenu panel). Drives hover highlight, submenu opening, and activation.
    func rowIndex(at point: Point) -> Int? {
        for (index, row) in rowViews.enumerated() where row.isEnabled && row.frame.contains(point) {
            return index
        }
        return nil
    }

    /// The item backing a visible row, for the host to read its submenu and token.
    func item(at index: Int) -> MenuItem? {
        rowViews.indices.contains(index) ? rowViews[index].item : nil
    }

    /// The panel-local frame of a visible row, where its submenu panel anchors.
    func rowFrame(at index: Int) -> Rect? {
        rowViews.indices.contains(index) ? rowViews[index].frame : nil
    }

    /// The current selection (pointer hover and keyboard share it).
    var highlightedRowIndex: Int? { highlightedIndex }

    /// The panel size that fits every row: the widest measured row label plus the
    /// insets (and an arrow column when any row has a submenu), clamped to the
    /// metric bounds, by the stacked row/separator height.
    var preferredSize: Size {
        let hasArrow = menu.items.contains { $0.submenu != nil }
        var widest: Double = 0
        for row in rowViews {
            widest = max(widest, row.measuredLabelWidth)
        }
        let arrowColumn = hasArrow ? MenuMetrics.arrowWidth : 0
        let rawWidth = MenuMetrics.leadingInset + widest + arrowColumn + MenuMetrics.trailingInset
        let width = min(MenuMetrics.maxWidth, max(MenuMetrics.minWidth, rawWidth))
        var height = MenuMetrics.verticalPadding * 2
        for item in menu.items {
            height += item.isSeparator ? MenuMetrics.separatorHeight : MenuMetrics.rowHeight
        }
        return Size(width: width, height: height)
    }

    /// Set the selection by row index (pointer hover or programmatic), highlighting
    /// only `index` and clearing the rest. Nil clears all.
    func setHighlightedIndex(_ index: Int?) {
        highlightedIndex = index
        for (rowIndex, row) in rowViews.enumerated() {
            row.setHighlighted(rowIndex == index)
        }
    }

    /// Move the keyboard selection by `delta` (−1 up, +1 down), skipping disabled
    /// rows and wrapping at the ends (the macOS menu behavior). With no current
    /// selection it lands on the first enabled row going down, the last going up.
    func moveHighlight(by delta: Int) {
        let enabled = rowViews.indices.filter { rowViews[$0].isEnabled }
        guard !enabled.isEmpty else { return }
        let next: Int
        if let current = highlightedIndex, let pos = enabled.firstIndex(of: current) {
            let count = enabled.count
            next = enabled[((pos + delta) % count + count) % count]
        } else {
            next = delta < 0 ? enabled[enabled.count - 1] : enabled[0]
        }
        setHighlightedIndex(next)
    }

    override func layout() {
        let bounds = frame
        let width = bounds.size.width
        backgroundEffectView.frame = Rect(x: 0, y: 0, width: width, height: bounds.size.height)
        let appearance = effectiveAppearance
        let separatorColor = SemanticColor.separator.resolve(in: appearance)
        var y = MenuMetrics.verticalPadding
        var rowIndex = 0
        var separatorIndex = 0
        for item in menu.items {
            if item.isSeparator {
                let separator = separatorViews[separatorIndex]
                separatorIndex += 1
                separator.backgroundColor = separatorColor
                separator.frame = Rect(
                    x: MenuMetrics.leadingInset,
                    y: y + (MenuMetrics.separatorHeight - 1) * 0.5,
                    width: max(0, width - MenuMetrics.leadingInset * 2),
                    height: 1
                )
                y += MenuMetrics.separatorHeight
            } else {
                let row = rowViews[rowIndex]
                rowIndex += 1
                row.frame = Rect(x: 0, y: y, width: width, height: MenuMetrics.rowHeight)
                row.layoutIfNeeded()
                y += MenuMetrics.rowHeight
            }
        }
    }
}

/// A single menu row: a leading label, an optional trailing submenu arrow, and a
/// selection-tinted highlight behind both. Hover highlighting and activation are
/// driven by the host (which owns the pointer location and the grab) via
/// `setHighlighted` and the menu's `activateRow`; the row itself is a plain view.
private final class MenuRowView: View, ~Sendable {
    let item: MenuItem
    let isEnabled: Bool

    private let highlightView: View
    private let titleLabel: Label
    private let arrowLabel: Label?
    private var highlighted = false

    init(item: MenuItem) {
        self.item = item
        self.isEnabled = item.isEnabled
        self.highlightView = View()
        self.titleLabel = Label(item.label)
        self.arrowLabel = (item.submenu != nil) ? Label("\u{203A}") : nil
        super.init()
        highlightView.cornerRadius = 4
        highlightView.isHidden = true
        titleLabel.fontSize = MenuMetrics.fontSize
        addSubview(highlightView)
        addSubview(titleLabel)
        if let arrowLabel {
            arrowLabel.fontSize = MenuMetrics.fontSize
            arrowLabel.alignment = .center
            addSubview(arrowLabel)
        }
    }

    var measuredLabelWidth: Double {
        titleLabel.intrinsicContentSize.width
    }

    func setHighlighted(_ on: Bool) {
        let active = on && isEnabled
        guard highlighted != active else { return }
        highlighted = active
        highlightView.isHidden = !active
        setNeedsLayout()
    }

    override func layout() {
        let bounds = frame
        let width = bounds.size.width
        let height = bounds.size.height
        let appearance = effectiveAppearance
        let active = highlighted

        highlightView.backgroundColor = SemanticColor.accent.resolve(in: appearance)
        highlightView.frame = Rect(
            x: MenuMetrics.highlightInsetX,
            y: 1,
            width: max(0, width - MenuMetrics.highlightInsetX * 2),
            height: max(0, height - 2)
        )

        let textColor: Color =
            if !isEnabled {
                SemanticColor.tertiaryLabel.resolve(in: appearance)
            } else if active {
                SemanticColor.accentLabel.resolve(in: appearance)
            } else {
                SemanticColor.label.resolve(in: appearance)
            }
        titleLabel.textColor = textColor

        let arrowColumn = arrowLabel != nil ? MenuMetrics.arrowWidth : 0
        let textWidth = max(0, width - MenuMetrics.leadingInset - MenuMetrics.trailingInset - arrowColumn)
        titleLabel.centerVertically(in: Rect(
            x: MenuMetrics.leadingInset,
            y: 0,
            width: textWidth,
            height: height
        ))
        titleLabel.frame = Rect(
            x: MenuMetrics.leadingInset,
            y: titleLabel.frame.origin.y,
            width: textWidth,
            height: titleLabel.frame.size.height
        )

        if let arrowLabel {
            arrowLabel.textColor = textColor
            arrowLabel.centerVertically(in: Rect(
                x: width - MenuMetrics.trailingInset - arrowColumn,
                y: 0,
                width: arrowColumn,
                height: height
            ))
        }
    }
}
