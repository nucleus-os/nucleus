@_spi(NucleusCompositor) import NucleusLayers

@MainActor
open class View: Responder, Accessible, ~Sendable {
    package let backingLayer: Layer
    /// A `weak` handle to the context owning `backingLayer`'s registry, captured at
    /// init. The deinit prunes the registry through this rather than
    /// `backingLayer.context` — an `unowned` ref that traps if the context was torn
    /// down first (e.g. when a whole scene/context deallocates before its views). A
    /// dead context means the registry is already gone, so pruning is a safe no-op.
    private weak var registryContext: Context?
    package weak var parentView: View?
    package weak var parentWindow: Window?
    package weak var owningViewController: ViewController?
    package var childViews: [View]
    package var intrinsicContentSizeNeedsUpdate: Bool
    package var layoutNeedsUpdate: Bool
    package var displayNeedsUpdate: Bool
    /// Whether some descendant needs layout, even if this view does not. Without
    /// it `layoutIfNeeded` has to walk every view on every pass to find out.
    package var subtreeLayoutNeedsUpdate: Bool
    package var subtreeDisplayNeedsUpdate: Bool
    package var cachedRecording: PaintRecording
    package var storedStyle: ViewStyle
    package var storedAccessibilityProperties: AccessibilityProperties
    package var storedAccessibilityChildren: [any Accessible]?
    package var storedTransform: Transform
    package var storedLayerPresentation: ViewLayerPresentation

    public override init() {
        self.backingLayer = Application.currentContext.makeLayer()
        self.registryContext = backingLayer.context
        self.childViews = []
        self.intrinsicContentSizeNeedsUpdate = false
        self.layoutNeedsUpdate = false
        self.displayNeedsUpdate = true
        self.subtreeLayoutNeedsUpdate = false
        self.subtreeDisplayNeedsUpdate = true
        self.cachedRecording = PaintRecording()
        self.storedStyle = .none
        self.storedAccessibilityProperties = AccessibilityProperties()
        self.storedAccessibilityChildren = nil
        self.storedTransform = .identity
        self.storedLayerPresentation = .default
        super.init()
    }

    init(layerDescriptor: LayerDescriptor) {
        self.backingLayer = Application.currentContext.makeLayer(layerDescriptor)
        self.registryContext = backingLayer.context
        self.childViews = []
        self.intrinsicContentSizeNeedsUpdate = false
        self.layoutNeedsUpdate = false
        self.displayNeedsUpdate = true
        self.subtreeLayoutNeedsUpdate = false
        self.subtreeDisplayNeedsUpdate = true
        self.cachedRecording = PaintRecording()
        self.storedStyle = .none
        self.storedAccessibilityProperties = AccessibilityProperties()
        self.storedAccessibilityChildren = nil
        self.storedTransform = .identity
        self.storedLayerPresentation = .default
        super.init()
    }

    // `isolated deinit` runs the body on the `@MainActor` (the layer registry and
    // Layer/Context are `@MainActor`), so no non-Sendable state crosses an isolation
    // boundary.
    isolated deinit {
        // Drop the backing layer from the context's registry so it — and the
        // paint/content handle it retains via `descriptor.initialContent` — can
        // deallocate. `context.layers` co-owns every layer with its View, so without
        // this the layer (and its content) outlives the View for the context's whole
        // lifetime. A live subview is retained by its superview, so a View only
        // deinits after removeFromSuperview has already detached its layer from the
        // tree; this just releases the registry's last strong reference. Pruned
        // through the `weak` `registryContext`: if the context was already torn down
        // (a whole scene deallocating), the registry is gone and this is a no-op —
        // reading the layer's `unowned` context there would instead trap.
        registryContext?.layers.removeValue(forKey: backingLayer.id)
    }

    public func addSubview(_ child: View) {
        // Eager Swift-tree mutation: matches `NSView.addSubview`. The
        // FFI-side layer insert journals into whatever transaction is
        // currently active for this context (explicit if one is in
        // scope, otherwise the per-context implicit ambient buffer
        // which is flushed by the consumer's frame-time trigger).
        child.detachFromSwiftTree()
        childViews.append(child)
        child.parentView = self
        // The new child carries its own dirty state; the ancestors that will run
        // the next pass have to learn there is now work under them.
        markSubtreeNeedsLayout()
        markSubtreeNeedsDisplay()
        child.backingLayer.attach(to: backingLayer, at: UInt32.max)
        LayerTransaction.appendAmbient(
            .inserted(layer: child.backingLayer.id, parent: backingLayer.id, index: UInt32.max),
            in: backingLayer.context
        )
    }

    public func removeFromSuperview() {
        let layer = backingLayer
        let context = layer.context
        detachFromSwiftTree()
        layer.detach()
        LayerTransaction.appendAmbient(.detached(layer.id), in: context)
    }

    /// Apply a batched ViewProperties update. Local model state updates
    /// eagerly; the FFI commit is journaled into the active ambient
    /// transaction.
    public func setProperties(_ properties: ViewProperties) {
        let update = properties.layerUpdate()
        backingLayer.apply(update)
        LayerTransaction.appendAmbient(.properties(layer: backingLayer.id, update), in: backingLayer.context)
        if properties.frame != nil {
            setNeedsLayout()
        }
    }

    /// Live model frame, mirrors `NSView.frame`. Reads return the eagerly
    /// updated value; the setter applies eagerly and journals the layer
    /// update into the active ambient transaction (matches AppKit shape:
    /// no `try`, no error propagation at the model level).
    public var frame: Rect {
        get {
            let f = backingLayer.frame
            return Rect(x: f.x, y: f.y, width: f.width, height: f.height)
        }
        set {
            let update = LayerPropertyUpdate.decomposedFrame(
                GeometryRect(x: newValue.origin.x, y: newValue.origin.y, width: newValue.size.width, height: newValue.size.height)
            )
            backingLayer.apply(update)
            LayerTransaction.appendAmbient(.properties(layer: backingLayer.id, update), in: backingLayer.context)
            // The bounds clip is expressed in this view's size, so a resize
            // moves it.
            if clipsToBounds { applyBoundsClip() }
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    public var isHidden: Bool {
        get { backingLayer.isHidden }
        set {
            let update = LayerPropertyUpdate(isHidden: newValue)
            backingLayer.apply(update)
            LayerTransaction.appendAmbient(.properties(layer: backingLayer.id, update), in: backingLayer.context)
            parentView?.setNeedsDisplay()
        }
    }

    public var alphaValue: Double {
        get { backingLayer.opacity }
        set {
            let update = LayerPropertyUpdate(opacity: min(max(0, newValue), 1))
            backingLayer.apply(update)
            LayerTransaction.appendAmbient(.properties(layer: backingLayer.id, update), in: backingLayer.context)
        }
    }

    /// This view's own coordinate system, mirroring `NSView.bounds`.
    ///
    /// The size is the frame's size — a view's size is its frame's, and `bounds`
    /// reports it rather than owning it. The *origin* is this view's alone: it
    /// translates between these coordinates and the view's contents, so a view
    /// with `bounds.origin == (0, 40)` shows its contents shifted up by forty
    /// points without any child's `frame` changing.
    ///
    /// That separation is the point. `arrange(in:)` rewrites child frames on
    /// every layout pass, so a scroll offset stored there would be destroyed and
    /// have to be re-applied by every container forever. Layout never writes
    /// `bounds.origin`, and so stays unaware that scrolling exists.
    public var bounds: Rect {
        get {
            Rect(
                x: boundsOrigin.x, y: boundsOrigin.y,
                width: frame.size.width, height: frame.size.height)
        }
        set {
            // Size is the frame's to own; assigning it here would contradict
            // layout on the next pass. Only the origin is stored.
            boundsOrigin = newValue.origin
        }
    }

    /// The bounds origin, stored. Assigning it moves this view's contents
    /// without touching a single child frame or re-recording any drawing: the
    /// children's layers are placed relative to it, so a scroll is one property
    /// update rather than one per child.
    public var boundsOrigin: Point = .zero {
        didSet {
            guard boundsOrigin != oldValue else { return }
            let update = LayerPropertyUpdate(
                scrollOffset: GeometryPoint(x: boundsOrigin.x, y: boundsOrigin.y))
            backingLayer.apply(update)
            LayerTransaction.appendAmbient(
                .properties(layer: backingLayer.id, update), in: backingLayer.context)
            // Placement changes; recordings do not. Children are positioned
            // relative to this origin, so their own drawing is untouched.
            setNeedsDisplay()
        }
    }

    /// Whether this view clips its contents to its bounds.
    ///
    /// Mirrors `NSView.clipsToBounds`. Hit testing respects it as well as
    /// drawing: a child scrolled out of sight must not receive a click, and this
    /// is what makes it out of sight.
    public var clipsToBounds: Bool = false {
        didSet {
            guard clipsToBounds != oldValue else { return }
            applyBoundsClip()
        }
    }

    /// Push the bounds clip to the layer. A zero-sized clip rect is the render
    /// model's spelling of "no clip", which is what an unclipped view wants and
    /// also what a zero-sized view would produce anyway.
    private func applyBoundsClip() {
        let size = clipsToBounds ? frame.size : .zero
        let update = LayerPropertyUpdate(
            clip: ClipOp(
                rectX: 0, rectY: 0,
                rectW: Float(size.width), rectH: Float(size.height)))
        backingLayer.apply(update)
        LayerTransaction.appendAmbient(
            .properties(layer: backingLayer.id, update), in: backingLayer.context)
    }

    public var transform: Transform {
        get { storedTransform }
        set {
            storedTransform = newValue
            let update = LayerPropertyUpdate(transform: newValue.layersTransform)
            backingLayer.apply(update)
            LayerTransaction.appendAmbient(.properties(layer: backingLayer.id, update), in: backingLayer.context)
        }
    }

    public var style: ViewStyle {
        get { storedStyle }
        set {
            storedStyle = newValue
            setNeedsDisplay()
        }
    }

    public var backgroundColor: Color? {
        get { storedStyle.backgroundColor }
        set {
            storedStyle.backgroundColor = newValue
            setNeedsDisplay()
        }
    }

    public var cornerRadius: Double {
        get { storedStyle.cornerRadius }
        set {
            storedStyle.cornerRadius = max(0, newValue)
            setNeedsDisplay()
        }
    }

    public var border: Border {
        get { storedStyle.border }
        set {
            storedStyle.border = newValue
            setNeedsDisplay()
        }
    }

    /// Drop shadow on this view's backing layer. Mirrors `NSView.shadow`
    /// (composite NSShadow-style) — sets all four CALayer split shadow
    /// properties at once.
    public var shadow: Shadow {
        get { Shadow(backingLayer.descriptor.shadow) }
        set {
            let update = LayerPropertyUpdate(shadow: newValue.layersShadow)
            backingLayer.apply(update)
            LayerTransaction.appendAmbient(.properties(layer: backingLayer.id, update), in: backingLayer.context)
        }
    }

    public var backingLayerID: UInt64 {
        backingLayer.id.rawValue
    }

    /// Presentation metadata used when this view is materialized into an
    /// output-owned backing layer. Grouping role, action policy, and initial
    /// pose into one value keeps publication state snapshot-based instead of
    /// spreading lifecycle fields across the view.
    public var layerPresentation: ViewLayerPresentation {
        get { storedLayerPresentation }
        set { storedLayerPresentation = newValue }
    }

    /// Chainable variant for inline configuration. Mirrors SwiftUI's
    /// `.shadow(color:radius:x:y:)` modifier; returns `self` so the view
    /// can be passed to `addSubview` or held inline. Discardable result —
    /// the mutation is the point.
    @discardableResult
    public func shadow(
        color: Color = Color(0, 0, 0, 1),
        radius: Double,
        x: Double = 0,
        y: Double = 0,
        cornerRadius: Double = 0,
        opacity: Double = 1
    ) -> Self {
        shadow = Shadow(
            offsetX: x,
            offsetY: y,
            blurRadius: radius,
            cornerRadius: cornerRadius,
            opacity: opacity,
            color: color
        )
        return self
    }

    /// View-level snapshot of model properties. Subclasses with extra
    /// model state (e.g. `VisualEffectView` carrying a resolved
    /// `BackdropMaterial`) override to surface their additions.
    open var properties: ViewProperties {
        ViewProperties(frame: frame, isHidden: isHidden)
    }

    package var layerContent: ViewLayerContent {
        ViewLayerContent(
            recording: cachedRecording,
            presentation: layerPresentation,
            shadow: shadow == .none ? nil : shadow
        )
    }

    public var stableHandle: Handle {
        Handle(view: self)
    }

    public var isAccessibilityElement: Bool {
        get { storedAccessibilityProperties.isElement }
        set { storedAccessibilityProperties.isElement = newValue }
    }

    public var accessibilityLabel: String? {
        get { storedAccessibilityProperties.label }
        set { storedAccessibilityProperties.label = newValue }
    }

    // MARK: - Tracking

    /// This view's tracking areas, in the order added.
    public private(set) var trackingAreas: [TrackingArea] = []

    /// Whether the pointer is currently inside one of this view's tracking
    /// areas. Maintained by the scene, which is the only thing that can know the
    /// pointer left for a sibling.
    public internal(set) var isHovered: Bool = false {
        didSet {
            guard isHovered != oldValue else { return }
            hoverStateDidChange()
        }
    }

    /// Called when `isHovered` flips. The hook a view overrides to restyle,
    /// rather than watching enter/exit events.
    open func hoverStateDidChange() {
        setNeedsDisplay()
    }

    public func addTrackingArea(_ area: TrackingArea) {
        area.attach(to: self)
        trackingAreas.append(area)
    }

    public func removeTrackingArea(_ area: TrackingArea) {
        trackingAreas.removeAll { $0 === area }
        if trackingAreas.isEmpty { isHovered = false }
    }

    /// Add a whole-bounds tracking area, the common case. Returns it so a caller
    /// that wants to adjust or remove it later can hold on.
    @discardableResult
    public func addTracking(
        cursor: Cursor? = nil,
        toolTip: String? = nil,
        toolTipProvider: (() -> String?)? = nil
    ) -> TrackingArea {
        let area = TrackingArea(
            cursor: cursor, toolTip: toolTip, toolTipProvider: toolTipProvider)
        addTrackingArea(area)
        return area
    }

    /// The frontmost tracking area containing `point`, in this view's bounds
    /// coordinates. Later areas win, matching subview order: the most recently
    /// added is the most specific.
    public func trackingArea(at point: Point) -> TrackingArea? {
        trackingAreas.last { $0.contains(point, in: self) }
    }

    public var accessibilityHint: String? {
        get { storedAccessibilityProperties.hint }
        set { storedAccessibilityProperties.hint = newValue }
    }

    public var accessibilityValue: String? {
        get { storedAccessibilityProperties.value }
        set { storedAccessibilityProperties.value = newValue }
    }

    public var accessibilityRole: AccessibilityRole? {
        get { storedAccessibilityProperties.role }
        set { storedAccessibilityProperties.role = newValue }
    }

    public var accessibilityTraits: AccessibilityTraits {
        get { storedAccessibilityProperties.traits }
        set { storedAccessibilityProperties.traits = newValue }
    }

    public var accessibilityChildren: [any Accessible]? {
        get { storedAccessibilityChildren }
        set { storedAccessibilityChildren = newValue }
    }

    public var accessibilityProperties: AccessibilityProperties {
        get { storedAccessibilityProperties }
        set { storedAccessibilityProperties = newValue }
    }

    package func detachFromSwiftTree(clearOwningViewController: Bool = true) {
        if let parentView {
            parentView.childViews.removeAll { $0 === self }
        }
        if let parentWindow, parentWindow.rootView === self {
            parentWindow.rootView = nil
        }
        if clearOwningViewController, let owningViewController, owningViewController.rootView === self {
            owningViewController.clearLoadedView()
        }
        parentView = nil
        parentWindow = nil
        if clearOwningViewController {
            owningViewController = nil
        }
    }

    public var superview: View? {
        parentView
    }

    /// The window this view is installed in, found by walking up the view tree.
    /// `parentWindow` is only set on a window's root view, so a nested view has
    /// to climb. Mirrors `NSView.window`.
    public var window: Window? {
        var node: View? = self
        while let current = node {
            if let window = current.parentWindow { return window }
            node = current.parentView
        }
        return nil
    }

    public var subviews: [View] {
        childViews
    }

    /// Per-view appearance override. `nil` (the default) means inherit from
    /// the nearest ancestor that specifies one, falling back to
    /// `Appearance.systemDefault`. Mirrors `NSView.appearance`.
    public var appearance: Appearance?

    /// The appearance this view actually paints under. Walks the parent
    /// chain to the nearest non-nil `appearance`, falling back to
    /// `Appearance.systemDefault`. Mirrors `NSView.effectiveAppearance`.
    public var effectiveAppearance: Appearance {
        var current: View? = self
        while let view = current {
            if let appearance = view.appearance {
                return appearance
            }
            current = view.parentView
        }
        return Appearance.systemDefault
    }

    public var needsIntrinsicContentSizeUpdate: Bool {
        intrinsicContentSizeNeedsUpdate
    }

    public var needsLayout: Bool {
        layoutNeedsUpdate
    }

    public var needsDisplay: Bool {
        displayNeedsUpdate
    }

    /// This view's natural size with no constraint applied. The unconstrained
    /// case of `measure(_:)`; anything whose size depends on the space offered
    /// — wrapped text above all — must override `measure(_:)` too, because this
    /// question cannot express the answer.
    ///
    /// A pure read. It used to clear `intrinsicContentSizeNeedsUpdate` as a side
    /// effect, which meant merely *asking* a view its size silently marked it
    /// clean; the flag is now cleared by the layout pass that consumed it.
    open var intrinsicContentSize: Size {
        .zero
    }

    /// The size this view wants within `constraints`.
    ///
    /// The first half of two-phase layout: a parent measures children to decide
    /// how much room each gets, then `arrange(in:)` assigns final geometry.
    /// Measuring must not mutate geometry — a parent may measure the same child
    /// several times while resolving flexible space.
    open func measure(_ constraints: LayoutConstraints) -> Size {
        constraints.constrain(intrinsicContentSize)
    }

    /// Place this view at `rect` and lay its subtree out within it. The second
    /// half of two-phase layout.
    open func arrange(in rect: Rect) {
        if frame != rect {
            frame = rect
        }
        layoutIfNeeded()
    }

    // MARK: - Flexible sizing

    /// Share of a container's *surplus* main-axis space this view absorbs,
    /// relative to its siblings. `0` (the default) means "stay at measured size".
    public var growFactor: Double = 0 {
        didSet { if growFactor != oldValue { parentView?.setNeedsLayout() } }
    }

    /// Share of a container's main-axis *overflow* this view gives back, weighted
    /// by measured size. `1` by default, so children shrink together rather than
    /// letting the last one overflow.
    public var shrinkFactor: Double = 1 {
        didSet { if shrinkFactor != oldValue { parentView?.setNeedsLayout() } }
    }

    /// Main-axis starting size, overriding the measured one. `nil` means measure.
    public var layoutBasis: Double? = nil {
        didSet { if layoutBasis != oldValue { parentView?.setNeedsLayout() } }
    }

    open func invalidateIntrinsicContentSize() {
        intrinsicContentSizeNeedsUpdate = true
        // Both: this view's own layout depends on its size, and its container's
        // arrangement of siblings does too.
        setNeedsLayout()
        parentView?.setNeedsLayout()
    }

    open func setNeedsLayout() {
        guard !layoutNeedsUpdate else {
            return
        }
        layoutNeedsUpdate = true
        parentView?.markSubtreeNeedsLayout()
    }

    /// Record that *something below* needs layout, without dirtying this view's
    /// own arrangement. A child moving does not mean its parent must re-run
    /// `layout()`; it only means the pass has to reach that child.
    package func markSubtreeNeedsLayout() {
        var node: View? = self
        while let current = node, !current.subtreeLayoutNeedsUpdate {
            current.subtreeLayoutNeedsUpdate = true
            node = current.parentView
        }
    }

    package func markSubtreeNeedsDisplay() {
        var node: View? = self
        while let current = node, !current.subtreeDisplayNeedsUpdate {
            current.subtreeDisplayNeedsUpdate = true
            node = current.parentView
        }
    }

    open func setNeedsDisplay() {
        setNeedsDisplay(bounds)
    }

    /// Keeps AppKit's signature so callers are unaffected, but the rect only
    /// marks the view dirty — see `draw(in:)` on why a subrect cannot be
    /// honored here.
    open func setNeedsDisplay(_ rect: Rect) {
        _ = rect
        displayNeedsUpdate = true
        parentView?.markSubtreeNeedsDisplay()
    }

    open func layout() {
    }

    /// Draw this view's content. The framework paints `style` underneath
    /// first, so an override adds to the styled background rather than
    /// replacing it.
    ///
    /// There is no `dirtyRect`. Paint content registers a whole-canvas command
    /// list and rasterizes into a fresh texture, so a subrect-only redraw would
    /// produce a texture containing only that subrect — AppKit's contract
    /// preserves the undrawn pixels, and this pipeline structurally cannot.
    /// Partial repaint lands when a partial-texture-update path does.
    open func draw(in context: GraphicsContext) {
        _ = context
    }

    /// Run layout over the dirty part of this subtree. Clean subtrees are
    /// skipped outright: with a per-frame layout pass over a whole shell, walking
    /// every view to discover that nothing changed is the dominant cost.
    public func layoutIfNeeded() {
        guard layoutNeedsUpdate || subtreeLayoutNeedsUpdate else { return }
        if layoutNeedsUpdate {
            layoutNeedsUpdate = false
            intrinsicContentSizeNeedsUpdate = false
            layout()
        }
        // Cleared before recursing: `layout()` places children, which re-marks
        // this flag through their `frame` setters, and those children are exactly
        // the ones the loop below is about to visit.
        subtreeLayoutNeedsUpdate = false
        for child in childViews {
            child.layoutIfNeeded()
        }
    }

    public func displayIfNeeded() {
        guard displayNeedsUpdate || subtreeDisplayNeedsUpdate else { return }
        if displayNeedsUpdate {
            let context = GraphicsContext()
            storedStyle.draw(in: context, bounds: bounds)
            draw(in: context)
            cachedRecording = context.recording
            displayNeedsUpdate = false
        }
        subtreeDisplayNeedsUpdate = false
        for child in childViews {
            child.displayIfNeeded()
        }
    }

    open override var nextResponder: Responder? {
        get { parentView ?? owningViewController ?? parentWindow ?? explicitNextResponder }
        set { explicitNextResponder = newValue }
    }

    /// Hit-test `event.location` in this subtree and deliver the event to the
    /// view found, then up its responder chain. The location is rebased into
    /// each view's own coordinates on the way down.
    ///
    /// This is single-tree dispatch with no pointer capture. `WindowScene`
    /// dispatch adds capture and enter/exit tracking, which need scene-wide
    /// state; a view alone cannot know the pointer left it for a sibling.
    /// Convert `point` from `view`'s coordinate system into this view's.
    /// A `nil` view means window coordinates. Mirrors `NSView.convert(_:from:)`.
    ///
    /// Both sides route through the window, and the terms for any shared
    /// ancestor cancel, so this is also correct for two views in a tree that has
    /// no window yet.
    public func convert(_ point: Point, from view: View?) -> Point {
        convertFromWindowSpace(view?.convertToWindowSpace(point) ?? point)
    }

    /// Convert `point` from this view's coordinate system into `view`'s.
    /// A `nil` view means window coordinates.
    public func convert(_ point: Point, to view: View?) -> Point {
        view?.convert(point, from: self) ?? convertToWindowSpace(point)
    }

    public func convert(_ rect: Rect, from view: View?) -> Rect {
        Rect(origin: convert(rect.origin, from: view), size: rect.size)
    }

    public func convert(_ rect: Rect, to view: View?) -> Rect {
        Rect(origin: convert(rect.origin, to: view), size: rect.size)
    }

    /// Up the tree: undo this view's scroll, then step out through its frame.
    /// The inverse of the rebase `hitTest` performs on the way down, and the
    /// single definition of the coordinate system.
    private func convertToWindowSpace(_ point: Point) -> Point {
        var result = point
        var node: View? = self
        while let current = node {
            result = Point(
                x: result.x - current.boundsOrigin.x + current.frame.origin.x,
                y: result.y - current.boundsOrigin.y + current.frame.origin.y)
            node = current.parentView
        }
        return result
    }

    private func convertFromWindowSpace(_ point: Point) -> Point {
        var chain: [View] = []
        var node: View? = self
        while let current = node {
            chain.append(current)
            node = current.parentView
        }
        var result = point
        for current in chain.reversed() {
            result = Point(
                x: result.x - current.frame.origin.x + current.boundsOrigin.x,
                y: result.y - current.frame.origin.y + current.boundsOrigin.y)
        }
        return result
    }

    /// Hit-test `event.location` and deliver to the view found, then up its
    /// responder chain.
    ///
    /// `event.location` is in *this view's parent's* coordinates, matching
    /// `hitTest`. The delivered event carries the location in the target's own
    /// coordinates.
    @discardableResult
    public func dispatchEvent(_ event: Event) -> EventHandling {
        guard let target = hitTest(event.location) else { return .notHandled }
        // Into this view's own coordinates first, since the incoming location is
        // in its parent's; `convert(_:from:)` then speaks view-to-view.
        let localInSelf = Point(
            x: event.location.x - frame.origin.x + boundsOrigin.x,
            y: event.location.y - frame.origin.y + boundsOrigin.y)
        let local = target.convert(localInSelf, from: self)
        return target.deliverEvent(event.relocated(to: local))
    }

    open func hitTest(_ point: Point) -> View? {
        guard !isHidden else {
            return nil
        }

        let ownFrame = frame
        guard ownFrame.contains(point) else {
            return nil
        }

        // Into this view's own coordinates: past the frame origin, then past the
        // bounds origin, which is where a scrolled view's contents actually sit.
        let localPoint = Point(
            x: point.x - ownFrame.origin.x + boundsOrigin.x,
            y: point.y - ownFrame.origin.y + boundsOrigin.y
        )

        // A clipping view hides whatever falls outside it, and something hidden
        // must not be clickable. Checked after the rebase, because the clip is
        // this view's bounds and `localPoint` is now in them.
        if clipsToBounds && !bounds.contains(localPoint) {
            return self
        }

        for child in childViews.reversed() {
            if let hit = child.hitTest(localPoint) {
                return hit
            }
        }
        return self
    }
}
