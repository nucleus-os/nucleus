public import NucleusUI

/// A thing that sits in the bar.
///
/// The reference's `Widget` base class is `create` / `doLayout` / `doUpdate` /
/// `onPointerEvent` / `onFrameTick`, plus styling state and a panel-toggle
/// callback. Three of those five are already `View`'s job here — construction,
/// layout, and event handling — so what a widget adds is a pull from whatever
/// it displays. Animated widgets use `UIContext` animation demand.
///
/// A widget never presents its own panel. It has no scene and could not test one
/// by assignment if it did; it reports that it was activated and the bar decides
/// what opens.
@MainActor
open class BarWidget: View {
    /// Re-read whatever this widget displays and update its views.
    ///
    /// Called when the bar is told the world changed. The default does nothing,
    /// because a widget driven purely by property assignment — which most are —
    /// has already updated by the time anyone could call this.
    open func refresh() {}

    /// The widget was activated — clicked, or otherwise asked to open its panel.
    ///
    /// The rect is the widget's frame in bar coordinates, so a panel can be
    /// anchored under the thing that opened it.
    public var onActivateWidget: ((BarWidget, Rect) -> Void)?

    /// Names the panel this widget opens, for the registry that will own panels.
    /// Empty means the widget opens nothing.
    public var panelIdentifier: String = ""

    /// Whether the bar draws a capsule behind this widget.
    ///
    /// Consecutive capsule widgets share one, which is why this is the bar's
    /// decision to render and the widget's only to declare.
    public var showsCapsule: Bool = true {
        didSet { if showsCapsule != oldValue { barNeedsChromeUpdate?() } }
    }

    /// Set by the bar so a widget can ask for its chrome to be recomputed.
    /// Nil while the widget is not in a bar.
    var barNeedsChromeUpdate: (() -> Void)?

    /// The colour the widget's own content draws in.
    public var contentTint: ColorSpec = .role(.onSurface) {
        didSet { if contentTint != oldValue { setNeedsDisplay() } }
    }

    /// Report activation, with this widget's frame in the bar's coordinates.
    public func activate() {
        let anchor = barCoordinateFrame()
        onActivateWidget?(self, anchor)
    }

    /// This widget's frame in the enclosing bar's coordinates, or its own frame
    /// when it is not in one.
    func barCoordinateFrame() -> Rect {
        var node: View? = superview
        while let current = node {
            if let bar = current as? BarView {
                return bar.convert(bounds, from: self)
            }
            node = current.superview
        }
        return frame
    }
}
