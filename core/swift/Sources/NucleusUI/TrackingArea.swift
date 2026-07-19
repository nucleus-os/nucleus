/// A region of a view that reports the pointer entering and leaving it, and
/// that can carry a cursor and a tooltip.
///
/// Mirrors `NSTrackingArea`, and covers what the reference's `InputArea` does:
/// hover, a cursor shape, and a tooltip with a content provider.
///
/// The rect is in the owning view's **bounds** coordinates, so a scrolled view's
/// tracking regions move with its contents rather than staying where they were
/// first placed.
@MainActor
public final class TrackingArea {
    /// The tracked region in the owner's bounds coordinates, or `nil` to track
    /// the whole of the owner's bounds however it is later resized.
    ///
    /// Tracking the whole view is overwhelmingly the common case — a bar widget
    /// wants "am I hovered", not a sub-rectangle — and spelling it as `nil`
    /// avoids every owner having to re-set a rect from `layout()`.
    public var rect: Rect?

    /// The cursor to show while the pointer is inside. `nil` inherits whatever
    /// an ancestor resolves to.
    public var cursor: Cursor?

    /// Static tooltip text. `toolTipProvider` takes precedence when both are set.
    public var toolTip: String?

    /// Tooltip text computed when the tooltip is about to appear.
    ///
    /// A provider rather than a stored string because the interesting tooltips
    /// are live: a battery's estimate, a network's throughput. Returning `nil`
    /// suppresses the tooltip for this hover.
    public var toolTipProvider: (() -> String?)?

    public private(set) weak var owner: View?

    public init(
        rect: Rect? = nil,
        cursor: Cursor? = nil,
        toolTip: String? = nil,
        toolTipProvider: (() -> String?)? = nil
    ) {
        self.rect = rect
        self.cursor = cursor
        self.toolTip = toolTip
        self.toolTipProvider = toolTipProvider
    }

    /// The effective tooltip text, provider first.
    public func resolvedToolTip() -> String? {
        if let toolTipProvider { return toolTipProvider() }
        return toolTip
    }

    /// Whether `point`, in the owner's bounds coordinates, is inside.
    public func contains(_ point: Point, in owner: View) -> Bool {
        (rect ?? owner.bounds).contains(point)
    }

    func attach(to view: View) {
        owner = view
    }
}
