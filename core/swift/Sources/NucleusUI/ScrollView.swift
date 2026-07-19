/// Which scroll indicators a scroll view shows.
public struct ScrollIndicators: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let vertical = ScrollIndicators(rawValue: 1 << 0)
    public static let horizontal = ScrollIndicators(rawValue: 1 << 1)
    public static let both: ScrollIndicators = [.vertical, .horizontal]
}

/// The clipping container a scroll view scrolls.
///
/// `NSClipView`'s role: it clips, and its `bounds.origin` *is* the scroll
/// position. There is nothing else to it, which is the point — scrolling is one
/// property assignment on this view, and the document inside neither moves nor
/// redraws.
@MainActor
public final class ClipView: View {
    public override init() {
        super.init()
        clipsToBounds = true
    }
}

/// A scrolling container: a clip view, a document view, and indicators.
///
/// Mirrors `NSScrollView`. Deliberately *not* virtualized — virtualization
/// belongs to a list view that knows its rows are uniform, exactly as AppKit
/// puts it in `NSTableView` rather than here. A scroll view that tried to
/// virtualize an arbitrary document view would have to guess at its structure.
@MainActor
open class ScrollView: View {
    public let clipView = ClipView()

    /// The scrolled content. Assigning replaces whatever was there.
    public var documentView: View? {
        didSet {
            guard documentView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let documentView { clipView.addSubview(documentView) }
            setNeedsLayout()
            clampScrollPosition()
        }
    }

    public var indicators: ScrollIndicators = .vertical {
        didSet { if indicators != oldValue { setNeedsDisplay() } }
    }

    /// How far one wheel notch scrolls. Continuous devices report their own
    /// deltas and bypass this.
    public var lineScrollDistance: Double = 40

    /// Called after the scroll position changes, whatever moved it.
    public var onScroll: ((Point) -> Void)?

    private static let indicatorThickness: Double = 4
    private static let indicatorInset: Double = 2
    private static let indicatorMinimumLength: Double = 24

    public override init() {
        super.init()
        clipsToBounds = true
        addSubview(clipView)
    }

    // MARK: - Scroll position

    /// The scroll position: the clip view's bounds origin, and nothing else.
    public var contentOffset: Point {
        get { clipView.boundsOrigin }
        set {
            let clamped = clampedOffset(newValue)
            guard clamped != clipView.boundsOrigin else { return }
            clipView.boundsOrigin = clamped
            // The indicators are drawn by this view, so they redraw even though
            // nothing inside the clip view did.
            setNeedsDisplay()
            onScroll?(clamped)
        }
    }

    /// The scrollable content's size — the document view's, or zero without one.
    public var contentSize: Size {
        documentView?.frame.size ?? .zero
    }

    /// How far the content can scroll on each axis. Zero when the content fits.
    public var maximumOffset: Point {
        let visible = clipView.frame.size
        let content = contentSize
        return Point(
            x: max(0, content.width - visible.width),
            y: max(0, content.height - visible.height))
    }

    private func clampedOffset(_ offset: Point) -> Point {
        let maximum = maximumOffset
        return Point(
            x: min(max(0, offset.x), maximum.x),
            y: min(max(0, offset.y), maximum.y))
    }

    /// Re-clamp after anything that could have shrunk the scrollable range.
    ///
    /// Without this, a document that shrinks while scrolled to its end leaves
    /// the view showing empty space past the content with no way back.
    public func clampScrollPosition() {
        let clamped = clampedOffset(clipView.boundsOrigin)
        if clamped != clipView.boundsOrigin {
            clipView.boundsOrigin = clamped
            onScroll?(clamped)
        }
    }

    /// Scroll the minimum distance needed to bring `rect`, in the document
    /// view's coordinates, into view. Mirrors `NSView.scrollToVisible`.
    ///
    /// The minimum rather than centring: a keyboard-driven scroll that recentred
    /// on every step would move content the user is reading.
    @discardableResult
    public func scrollToVisible(_ rect: Rect) -> Bool {
        let visible = Rect(origin: contentOffset, size: clipView.frame.size)
        var offset = contentOffset

        if rect.origin.x < visible.origin.x {
            offset.x = rect.origin.x
        } else if rect.origin.x + rect.size.width > visible.origin.x + visible.size.width {
            offset.x = rect.origin.x + rect.size.width - visible.size.width
        }

        if rect.origin.y < visible.origin.y {
            offset.y = rect.origin.y
        } else if rect.origin.y + rect.size.height > visible.origin.y + visible.size.height {
            offset.y = rect.origin.y + rect.size.height - visible.size.height
        }

        let before = contentOffset
        contentOffset = offset
        return contentOffset != before
    }

    // MARK: - Layout

    open override func layout() {
        clipView.frame = Rect(origin: .zero, size: bounds.size)
        // The document keeps its own size; the clip view is the window onto it.
        clampScrollPosition()
    }

    // MARK: - Events

    open override func handleEvent(_ event: Event) -> EventHandling {
        guard event.type == .scrollWheel else { return .notHandled }

        // A wheel reports notches, so a line's worth of travel is this view's to
        // decide; a high-resolution wheel reports fractions of one and scrolls
        // smoothly for free. A touchpad reports distance and is used as given.
        let distance = event.scrollDistance(lineHeight: lineScrollDistance)
        let proposed = Point(
            x: contentOffset.x + distance.x,
            y: contentOffset.y + distance.y)

        let before = contentOffset
        contentOffset = proposed
        // Unhandled when it did not move, so a nested scroll view that has hit
        // its end passes the scroll to its parent rather than swallowing it.
        return contentOffset == before ? .notHandled : .handled
    }

    // MARK: - Indicators

    open override func draw(in context: GraphicsContext) {
        guard let vertical = verticalIndicatorRect() else {
            drawHorizontalIndicator(in: context)
            return
        }
        var path = Path()
        path.addRoundedRect(vertical, radius: ScrollView.indicatorThickness / 2)
        context.fillColor = Color(1, 1, 1, 0.28)
        context.fill(path)
        drawHorizontalIndicator(in: context)
    }

    private func drawHorizontalIndicator(in context: GraphicsContext) {
        guard let rect = horizontalIndicatorRect() else { return }
        var path = Path()
        path.addRoundedRect(rect, radius: ScrollView.indicatorThickness / 2)
        context.fillColor = Color(1, 1, 1, 0.28)
        context.fill(path)
    }

    /// The vertical indicator's rect, or `nil` when there is nothing to
    /// indicate. Extracted from `draw` because this is the geometry worth
    /// testing: a path command carries its points in the payload blob.
    public func verticalIndicatorRect() -> Rect? {
        guard indicators.contains(.vertical) else { return nil }
        let travel = maximumOffset.y
        guard travel > 0 else { return nil }

        let track = bounds.size.height - ScrollView.indicatorInset * 2
        let visible = clipView.frame.size.height
        let proportion = visible / max(visible + travel, 1)
        let length = max(ScrollView.indicatorMinimumLength, track * proportion)
        let progress = contentOffset.y / travel

        return Rect(
            x: bounds.origin.x + bounds.size.width
                - ScrollView.indicatorThickness - ScrollView.indicatorInset,
            y: bounds.origin.y + ScrollView.indicatorInset
                + (track - length) * progress,
            width: ScrollView.indicatorThickness,
            height: length)
    }

    public func horizontalIndicatorRect() -> Rect? {
        guard indicators.contains(.horizontal) else { return nil }
        let travel = maximumOffset.x
        guard travel > 0 else { return nil }

        let track = bounds.size.width - ScrollView.indicatorInset * 2
        let visible = clipView.frame.size.width
        let proportion = visible / max(visible + travel, 1)
        let length = max(ScrollView.indicatorMinimumLength, track * proportion)
        let progress = contentOffset.x / travel

        return Rect(
            x: bounds.origin.x + ScrollView.indicatorInset
                + (track - length) * progress,
            y: bounds.origin.y + bounds.size.height
                - ScrollView.indicatorThickness - ScrollView.indicatorInset,
            width: length,
            height: ScrollView.indicatorThickness)
    }
}
