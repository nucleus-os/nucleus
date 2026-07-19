/// How a popup goes away.
public struct PopoverDismissal: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    /// A press anywhere outside dismisses. The usual behaviour for a menu or a
    /// panel opened from a bar widget.
    public static let outsideClick = PopoverDismissal(rawValue: 1 << 0)
    /// Escape dismisses.
    public static let escapeKey = PopoverDismissal(rawValue: 1 << 1)
    /// A press anywhere dismisses, without consuming the press. What a tooltip
    /// wants: it is describing something, not blocking it, so the click it
    /// cancels should still reach whatever was clicked.
    public static let anyClickPassively = PopoverDismissal(rawValue: 1 << 2)

    public static let standard: PopoverDismissal = [.outsideClick, .escapeKey]
}

/// A transient surface anchored to a rect: a menu, a dropdown, a panel opened
/// from a bar widget, a tooltip.
///
/// Mirrors `NSPopover` in role rather than in API — it is a `Window` with an
/// anchor and a dismissal policy, because the scene already knows how to order,
/// hit-test, and route events to windows. Inventing a parallel mechanism for
/// popups would mean teaching two things about levels and focus.
@MainActor
public final class Popover {
    public let window: Window

    /// The anchor in scene coordinates. Re-anchoring reflows the popover.
    public var anchor: Rect {
        didSet { if anchor != oldValue { reposition() } }
    }

    public var preferredEdge: PopupEdge {
        didSet { if preferredEdge != oldValue { reposition() } }
    }

    public var dismissal: PopoverDismissal

    /// Where the popover actually landed. A caller drawing an arrow needs the
    /// edge, which is not always the preferred one.
    public private(set) var placement: PopupPlacement

    /// Called after the popover leaves the scene, whatever dismissed it.
    public var onDismiss: (() -> Void)?

    /// The bounds placement is resolved inside — the display, in scene
    /// coordinates.
    var sceneBounds: Rect = .zero {
        didSet { if sceneBounds != oldValue { reposition() } }
    }

    private let contentSize: Size

    public init(
        content: View,
        anchor: Rect,
        preferring edge: PopupEdge = .below,
        dismissal: PopoverDismissal = .standard,
        level: WindowLevel = .overlay
    ) {
        let size = content.frame.size == .zero
            ? content.intrinsicContentSize
            : content.frame.size
        self.contentSize = size
        self.anchor = anchor
        self.preferredEdge = edge
        self.dismissal = dismissal
        self.placement = PopupPlacement(
            frame: Rect(origin: .zero, size: size), edge: edge)

        window = Window(
            title: "", frame: Rect(origin: .zero, size: size),
            role: .statusOverlay, level: level)
        content.frame = Rect(origin: .zero, size: size)
        window.setContentView(content)
    }

    /// Chrome for the common case: a rounded, tinted backing behind `content`.
    ///
    /// A convenience rather than a requirement — a caller wanting different
    /// chrome passes an already-styled view to `init` instead.
    public static func withChrome(
        content: View,
        anchor: Rect,
        preferring edge: PopupEdge = .below,
        dismissal: PopoverDismissal = .standard,
        padding: EdgeInsets = EdgeInsets(top: 8, left: 10, bottom: 8, right: 10),
        level: WindowLevel = .overlay
    ) -> Popover {
        let size = content.frame.size == .zero
            ? content.intrinsicContentSize
            : content.frame.size

        let backing = View()
        backing.style = ViewStyle(
            backgroundColor: Color(0.11, 0.12, 0.16, 0.98),
            cornerRadius: 8,
            border: Border(width: 1, color: Color(1, 1, 1, 0.10)))
        backing.frame = Rect(
            x: 0, y: 0,
            width: size.width + padding.left + padding.right,
            height: size.height + padding.top + padding.bottom)
        content.frame = Rect(
            origin: Point(x: padding.left, y: padding.top), size: size)
        backing.addSubview(content)

        return Popover(
            content: backing, anchor: anchor, preferring: edge,
            dismissal: dismissal, level: level)
    }

    private func reposition() {
        guard sceneBounds != .zero else { return }
        placement = resolvePopupPlacement(
            anchor: anchor, size: contentSize,
            preferring: preferredEdge, within: sceneBounds)
        window.setFrame(placement.frame)
    }

    func place(in bounds: Rect) {
        sceneBounds = bounds
        reposition()
    }
}
