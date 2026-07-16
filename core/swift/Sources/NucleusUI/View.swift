@_spi(NucleusCompositor) import NucleusLayers

@MainActor
open class View: Responder, Accessible, ~Sendable {
    @_spi(NucleusCompositor) public let backingLayer: Layer
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
    package var dirtyDisplayRects: [Rect]
    package var cachedLayerContentCommands: [ViewLayerContentCommand]
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
        self.dirtyDisplayRects = []
        self.cachedLayerContentCommands = []
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
        self.dirtyDisplayRects = []
        self.cachedLayerContentCommands = []
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

    public var bounds: Rect {
        get { Rect(x: 0, y: 0, width: frame.size.width, height: frame.size.height) }
        set {
            let update = LayerPropertyUpdate(bounds: GeometrySize(width: newValue.size.width, height: newValue.size.height))
            backingLayer.apply(update)
            LayerTransaction.appendAmbient(.properties(layer: backingLayer.id, update), in: backingLayer.context)
            setNeedsLayout()
            setNeedsDisplay()
        }
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

    @_spi(NucleusCompositor) public var layerContent: ViewLayerContent {
        ViewLayerContent(
            commands: LayerContentBuilder.commands(
                style: storedStyle,
                bounds: bounds,
                additional: cachedLayerContentCommands
            ),
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

    open var intrinsicContentSize: Size {
        intrinsicContentSizeNeedsUpdate = false
        return .zero
    }

    open func invalidateIntrinsicContentSize() {
        intrinsicContentSizeNeedsUpdate = true
        parentView?.setNeedsLayout()
    }

    open func setNeedsLayout() {
        guard !layoutNeedsUpdate else {
            return
        }
        layoutNeedsUpdate = true
        parentView?.setNeedsLayout()
    }

    open func setNeedsDisplay() {
        setNeedsDisplay(bounds)
    }

    open func setNeedsDisplay(_ rect: Rect) {
        displayNeedsUpdate = true
        dirtyDisplayRects.append(rect)
    }

    open func layout() {
    }

    open func draw(_ dirtyRect: Rect) {
    }

    package func displayCommands(in dirtyRect: Rect) -> [ViewLayerContentCommand] {
        []
    }

    public func layoutIfNeeded() {
        if layoutNeedsUpdate {
            layout()
            layoutNeedsUpdate = false
        }
        for child in childViews {
            child.layoutIfNeeded()
        }
    }

    public func displayIfNeeded() {
        if displayNeedsUpdate {
            let dirtyRect = dirtyDisplayRects.last ?? bounds
            draw(dirtyRect)
            cachedLayerContentCommands = displayCommands(in: dirtyRect)
            dirtyDisplayRects.removeAll(keepingCapacity: true)
            displayNeedsUpdate = false
        }
        for child in childViews {
            child.displayIfNeeded()
        }
    }

    open override var nextResponder: Responder? {
        get { parentView ?? owningViewController ?? parentWindow ?? explicitNextResponder }
        set { explicitNextResponder = newValue }
    }

    open func hitTest(_ point: Point) -> View? {
        guard !isHidden else {
            return nil
        }

        let ownFrame = frame
        guard ownFrame.contains(point) else {
            return nil
        }

        let localPoint = Point(
            x: point.x - ownFrame.origin.x,
            y: point.y - ownFrame.origin.y
        )
        for child in childViews.reversed() {
            if let hit = child.hitTest(localPoint) {
                return hit
            }
        }
        return self
    }
}
