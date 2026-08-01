package import NucleusLayers

package struct WindowScene: Sendable, Equatable {
    package var surfaceID: UInt64
    package var rootLayer: LayerID
    package var contentLayer: LayerID
    package var popupLayer: LayerID
    package var backingLayer: LayerID?
    package var frame: GeometryRect
    /// Transient snapshot-overlay layer during a tiling content crossfade (a sibling above
    /// the backing showing a frozen pre-tile snapshot, fading out). Nil when no crossfade.
    /// `applyGeometry` authors it with the backing's identical transform, so they overlay
    /// exactly.
    package var overlaySnapshotLayer: LayerID?
    /// Server-drawn titlebar band (the `NSThemeFrame` titlebar). A child of root in the
    /// reserved top inset, carrying a `.titlebar` backdrop material. Nil for borderless /
    /// fullscreen windows (no chrome).
    package var titlebarLayer: LayerID?
    /// Traffic-light control cluster — a fixed-size paint layer in the titlebar holding the
    /// close/minimize/maximize circles. Nil when the window has no titlebar.
    package var titlebarButtonLayer: LayerID?
    /// The focus state the button cluster was last painted for, so the circles repaint only
    /// when key-window focus flips rather than every frame. Nil until first painted.
    package var titlebarButtonsFocused: Bool?
    /// The hovered / pressed control button the cluster was last painted for, as the 1-based
    /// button code (0 = none, 1 = close, 2 = minimize, 3 = maximize). Driven by
    /// `setChromeButtonState` independently of layout so a hover or press repaints just the
    /// cluster.
    package var titlebarButtonsHovered: UInt32 = 0
    package var titlebarButtonsPressed: UInt32 = 0
    /// Titlebar band height, cached at layout so the layout-independent button repaint
    /// (`setChromeButtonState`) can size the cluster without a fresh layout pass.
    package var titlebarHeight: Double = 0

    package init(
        surfaceID: UInt64,
        rootLayer: LayerID,
        contentLayer: LayerID,
        popupLayer: LayerID = LayerID(rawValue: 0),
        backingLayer: LayerID? = nil,
        frame: GeometryRect = .zero,
        overlaySnapshotLayer: LayerID? = nil,
        titlebarLayer: LayerID? = nil,
        titlebarButtonLayer: LayerID? = nil,
        titlebarButtonsFocused: Bool? = nil
    ) {
        self.surfaceID = surfaceID
        self.rootLayer = rootLayer
        self.contentLayer = contentLayer
        self.popupLayer = popupLayer
        self.backingLayer = backingLayer
        self.frame = frame
        self.overlaySnapshotLayer = overlaySnapshotLayer
        self.titlebarLayer = titlebarLayer
        self.titlebarButtonLayer = titlebarButtonLayer
        self.titlebarButtonsFocused = titlebarButtonsFocused
    }
}
