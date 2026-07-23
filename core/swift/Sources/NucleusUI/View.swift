@_spi(NucleusCompositor) package import NucleusLayers
internal import enum NucleusTypes.LayerKind
internal import struct NucleusTypes.Rect

@MainActor
open class View: Responder, Accessible, ~Sendable {
    public let id: ViewID
    public let accessibilityID: AccessibilityID
    public let uiContext: UIContext
    package let semanticLayerKind: NucleusLayers.LayerKind
    package var semanticBackdropMaterial: BackdropMaterial
    package weak var parentView: View?
    package weak var parentWindow: Window?
    package weak var owningViewController: ViewController?
    package var childViews: [View]
    package var childViewsByID: [ViewID: View]
    package var childViewIndices: [ViewID: Int]
    package var dirtyChildViewIDs: Set<ViewID>
    package var intrinsicContentSizeNeedsUpdate: Bool
    package var layoutNeedsUpdate: Bool
    package var displayNeedsUpdate: Bool
    /// Whether some descendant needs layout, even if this view does not. Without
    /// it `layoutIfNeeded` has to walk every view on every pass to find out.
    package var subtreeLayoutNeedsUpdate: Bool
    package var subtreeDisplayNeedsUpdate: Bool
    package var cachedRecording: PaintRecording
    package var cachedPaintDamage: Rect?
    package var pendingDisplayDamage: Rect?
    package var storedStyle: ViewStyle
    package var storedAccessibilityProperties: AccessibilityProperties
    package var storedAccessibilityChildren: [any Accessible]?
    package var storedAccessibilityVirtualChildrenProvider:
        (@MainActor () -> [AccessibilityVirtualElement])?
    package var storedAccessibilityActions:
        [AccessibilityAction:
            @MainActor (AccessibilityActionRequest) -> Bool]
    package var storedTransform: Transform
    package var storedLayerPresentation: ViewLayerPresentation
    package var storedMutationActionPolicies: [ViewDirtyDomain: ActionPolicy]
    package var storedContextMenuProvider: (@MainActor () -> Menu)?
    package var storedDragSource: DragSourceConfiguration?
    package var storedDropDestination: DropDestinationConfiguration?
    package var storedDropDestinationGeneration: UInt64
    package var animationRequests: [AnimationKeyPath: ViewAnimationRequest]
    package var animationHandles: [UInt64: AnimationHandle]
    package var currentAnimationHandleIDs: [AnimationKeyPath: UInt64]
    package var ownedObservationTokens:
        [ObjectIdentifier: RetainedObservationToken]
    package var storedFadeTargetOpacity: Double?
    package var dirtyGenerations: ViewDirtyGenerations
    package var subtreeDirtyGenerations: ViewDirtyGenerations

    private var storedFrame: Rect
    private var storedIsHidden: Bool
    private var storedAlphaValue: Double
    private var storedBoundsOrigin: Point
    private var storedClipsToBounds: Bool
    private var storedShadow: Shadow
    private var storedIsHitTestingEnabled: Bool
    package var storedGrowFactor: Double = 0
    package var storedShrinkFactor: Double = 1
    package var storedLayoutBasis: Double?
    package var storedMinimumLayoutExtent: Double = 0
    package var storedMaximumLayoutExtent: Double = .infinity
    public var appearance: Appearance? {
        didSet {
            guard appearance != oldValue else { return }
            notifyEffectiveAppearanceChanged()
        }
    }
    public var palette: Palette? {
        didSet {
            guard palette != oldValue else { return }
            notifyEffectiveAppearanceChanged()
        }
    }

    public override init() {
        let uiContext = Application.currentUIContext
        self.id = uiContext.allocateViewID()
        self.accessibilityID = uiContext.allocateAccessibilityID()
        self.uiContext = uiContext
        self.semanticLayerKind = .container
        self.semanticBackdropMaterial = .none
        self.childViews = []
        self.childViewsByID = [:]
        self.childViewIndices = [:]
        self.dirtyChildViewIDs = []
        self.intrinsicContentSizeNeedsUpdate = false
        self.layoutNeedsUpdate = false
        self.displayNeedsUpdate = true
        self.subtreeLayoutNeedsUpdate = false
        self.subtreeDisplayNeedsUpdate = true
        self.cachedRecording = PaintRecording()
        self.cachedPaintDamage = nil
        self.pendingDisplayDamage = nil
        self.storedStyle = .none
        self.storedAccessibilityProperties = AccessibilityProperties()
        self.storedAccessibilityChildren = nil
        self.storedAccessibilityVirtualChildrenProvider = nil
        self.storedAccessibilityActions = [:]
        self.storedTransform = .identity
        self.storedLayerPresentation = .default
        self.storedMutationActionPolicies = [:]
        self.storedContextMenuProvider = nil
        self.storedDragSource = nil
        self.storedDropDestination = nil
        self.storedDropDestinationGeneration = 1
        self.animationRequests = [:]
        self.animationHandles = [:]
        self.currentAnimationHandleIDs = [:]
        self.ownedObservationTokens = [:]
        self.storedFadeTargetOpacity = nil
        self.dirtyGenerations = ViewDirtyGenerations()
        self.subtreeDirtyGenerations = ViewDirtyGenerations()
        self.storedFrame = .zero
        self.storedIsHidden = false
        self.storedAlphaValue = 1
        self.storedBoundsOrigin = .zero
        self.storedClipsToBounds = false
        self.storedShadow = .none
        self.storedIsHitTestingEnabled = true
        super.init()
        uiContext.registerEnvironmentConsumer(self)
    }

    init(layerDescriptor: LayerDescriptor) {
        let uiContext = Application.currentUIContext
        self.id = uiContext.allocateViewID()
        self.accessibilityID = uiContext.allocateAccessibilityID()
        self.uiContext = uiContext
        self.semanticLayerKind = layerDescriptor.kind
        self.semanticBackdropMaterial = layerDescriptor.backdropMaterial
        self.childViews = []
        self.childViewsByID = [:]
        self.childViewIndices = [:]
        self.dirtyChildViewIDs = []
        self.intrinsicContentSizeNeedsUpdate = false
        self.layoutNeedsUpdate = false
        self.displayNeedsUpdate = true
        self.subtreeLayoutNeedsUpdate = false
        self.subtreeDisplayNeedsUpdate = true
        self.cachedRecording = PaintRecording()
        self.cachedPaintDamage = nil
        self.pendingDisplayDamage = nil
        self.storedStyle = .none
        self.storedAccessibilityProperties = AccessibilityProperties()
        self.storedAccessibilityChildren = nil
        self.storedAccessibilityVirtualChildrenProvider = nil
        self.storedAccessibilityActions = [:]
        self.storedTransform = .identity
        self.storedLayerPresentation = .default
        self.storedMutationActionPolicies = [:]
        self.storedContextMenuProvider = nil
        self.storedDragSource = nil
        self.storedDropDestination = nil
        self.storedDropDestinationGeneration = 1
        self.animationRequests = [:]
        self.animationHandles = [:]
        self.currentAnimationHandleIDs = [:]
        self.ownedObservationTokens = [:]
        self.storedFadeTargetOpacity = nil
        self.dirtyGenerations = ViewDirtyGenerations()
        self.subtreeDirtyGenerations = ViewDirtyGenerations()
        self.storedFrame = Rect(
            x: layerDescriptor.frame.x,
            y: layerDescriptor.frame.y,
            width: layerDescriptor.frame.width,
            height: layerDescriptor.frame.height
        )
        self.storedIsHidden = layerDescriptor.isHidden
        self.storedAlphaValue = layerDescriptor.opacity
        self.storedBoundsOrigin = .zero
        self.storedClipsToBounds = false
        self.storedShadow = Shadow(layerDescriptor.shadow)
        self.storedIsHitTestingEnabled = true
        super.init()
        uiContext.registerEnvironmentConsumer(self)
    }

    isolated deinit {
        cancelOwnedObservations()
        uiContext.unregisterEnvironmentConsumer(id)
        uiContext.cancelAnimations(owner: self)
        cancelOwnedAnimationHandles()
    }

    public func addSubview(_ child: View) {
        insertSubview(child, at: childViews.count)
    }

    public func insertSubview(_ child: View, at requestedIndex: Int) {
        let currentIndex = child.parentView === self
            ? childViewIndices[child.id]
            : nil
        let finalCount = childViews.count
            - (currentIndex == nil ? 0 : 1)
        let index = min(max(0, requestedIndex), finalCount)
        if currentIndex == index {
            return
        }
        precondition(
            child.uiContext === uiContext,
            "a view cannot adopt a child from another UIContext")

        if let currentIndex {
            childViews.remove(at: currentIndex)
            childViews.insert(child, at: index)
            reindexChildren(startingAt: min(currentIndex, index))
            markSubtreeNeedsLayout()
            markSubtreeNeedsDisplay()
            recordMutation(.structure)
            return
        }

        child.detachFromSwiftTree()
        if index == childViews.endIndex {
            childViews.append(child)
        } else {
            childViews.insert(child, at: index)
        }
        childViewsByID[child.id] = child
        reindexChildren(startingAt: index)
        child.parentView = self
        // The new child carries its own dirty state; the ancestors that will run
        // the next pass have to learn there is now work under them.
        markSubtreeNeedsLayout()
        markSubtreeNeedsDisplay()
        recordMutation(.structure)
    }

    public func removeFromSuperview() {
        detachFromSwiftTree()
    }

    /// Remove direct children as one structural mutation. Hosts that receive a
    /// transaction-sized teardown use this instead of repeatedly shifting and
    /// reindexing the same sibling array.
    public func removeSubviews(_ children: [View]) {
        let removedIDs = Set(children.lazy.compactMap { child in
            child.parentView === self ? child.id : nil
        })
        guard !removedIDs.isEmpty else { return }

        var retained: [View] = []
        retained.reserveCapacity(childViews.count - removedIDs.count)
        for child in childViews {
            guard removedIDs.contains(child.id) else {
                retained.append(child)
                continue
            }
            child.notifyRetainedHierarchyWillDetach()
            child.window?.windowScene?.cancelInputSequences(capturedBy: child)
            if let owningViewController = child.owningViewController,
               owningViewController.rootView === child
            {
                owningViewController.clearLoadedView()
            }
            child.parentView = nil
            child.parentWindow = nil
            child.owningViewController = nil
            childViewsByID[child.id] = nil
            childViewIndices[child.id] = nil
        }
        childViews = retained
        childViewIndices.removeAll(keepingCapacity: true)
        reindexChildren(startingAt: 0)
        markSubtreeNeedsLayout()
        markSubtreeNeedsDisplay()
        recordMutation(.structure)
    }

    /// Called before this view leaves a retained hierarchy or its owning scene
    /// disconnects. Subclasses cancel work whose result must not outlive that
    /// attachment. The callback runs parent-before-child.
    open func retainedHierarchyWillDetach() {
        window?.windowScene?.dragParticipantWillDetach(self)
    }

    /// Apply a batched semantic update. Publication diffs the resulting model
    /// state into one visual transaction.
    public func setProperties(_ properties: ViewProperties) {
        if let frame = properties.frame {
            self.frame = frame
        }
        if let isHidden = properties.isHidden {
            self.isHidden = isHidden
        }
        if let backdropMaterial = properties.backdropMaterial,
           backdropMaterial != semanticBackdropMaterial
        {
            semanticBackdropMaterial = backdropMaterial
            recordMutation(.style)
        }
    }

    /// Live semantic frame, mirroring `NSView.frame`.
    public var frame: Rect {
        get { storedFrame }
        set {
            precondition(
                newValue.isFinite
                    && newValue.size.width >= 0
                    && newValue.size.height >= 0,
                "a view frame must be finite with nonnegative dimensions")
            guard newValue != storedFrame else { return }
            let sizeChanged = newValue.size != storedFrame.size
            storedFrame = newValue
            recordMutation(.geometry)
            if sizeChanged {
                setNeedsLayout()
                setNeedsDisplay()
            }
        }
    }

    public var isHidden: Bool {
        get { storedIsHidden }
        set {
            guard newValue != storedIsHidden else { return }
            storedIsHidden = newValue
            recordMutation(.visibility)
        }
    }

    public var alphaValue: Double {
        get { storedAlphaValue }
        set {
            precondition(
                newValue.isFinite,
                "view alpha must be finite")
            let value = min(max(0, newValue), 1)
            guard value != storedAlphaValue else { return }
            storedAlphaValue = value
            recordMutation(.visibility)
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
    public var boundsOrigin: Point {
        get { storedBoundsOrigin }
        set {
            precondition(
                newValue.isFinite,
                "a view bounds origin must be finite")
            guard newValue != storedBoundsOrigin else { return }
            storedBoundsOrigin = newValue
            recordMutation(.scrolling)
        }
    }

    /// Whether this view clips its contents to its bounds.
    ///
    /// Corresponds to `NSView.clipsToBounds`. Hit testing respects it as well as
    /// drawing: a child scrolled out of sight must not receive a click, and this
    /// is what makes it out of sight.
    public var clipsToBounds: Bool {
        get { storedClipsToBounds }
        set {
            guard newValue != storedClipsToBounds else { return }
            storedClipsToBounds = newValue
            recordMutation(.style)
        }
    }

    public var transform: Transform {
        get { storedTransform }
        set {
            precondition(
                newValue.isFinite,
                "a view transform must be finite")
            guard newValue != storedTransform else { return }
            storedTransform = newValue
            recordMutation(.transform)
        }
    }

    public var style: ViewStyle {
        get { storedStyle }
        set {
            precondition(
                newValue.cornerRadius.isFinite,
                "a view style corner radius must be finite")
            guard newValue != storedStyle else { return }
            storedStyle = newValue
            recordMutation(.style)
            setNeedsDisplay()
        }
    }

    public var backgroundColor: Color? {
        get { storedStyle.backgroundColor }
        set {
            guard newValue != storedStyle.backgroundColor else { return }
            storedStyle.backgroundColor = newValue
            recordMutation(.style)
            setNeedsDisplay()
        }
    }

    public var cornerRadius: Double {
        get { storedStyle.cornerRadius }
        set {
            precondition(
                newValue.isFinite,
                "a view corner radius must be finite")
            let value = max(0, newValue)
            guard value != storedStyle.cornerRadius else { return }
            storedStyle.cornerRadius = value
            recordMutation(.style)
            setNeedsDisplay()
        }
    }

    public var border: Border {
        get { storedStyle.border }
        set {
            guard newValue != storedStyle.border else { return }
            storedStyle.border = newValue
            recordMutation(.style)
            setNeedsDisplay()
        }
    }

    /// Drop shadow on this view's backing layer. Corresponds to `NSView.shadow`
    /// (composite NSShadow-style) — sets all four CALayer split shadow
    /// properties at once.
    public var shadow: Shadow {
        get { storedShadow }
        set {
            guard newValue != storedShadow else { return }
            storedShadow = newValue
            recordMutation(.style)
        }
    }

    /// Presentation metadata used when this view is materialized into an
    /// output-owned backing layer. Grouping role, action policy, and initial
    /// pose into one value keeps publication state snapshot-based instead of
    /// spreading lifecycle fields across the view.
    public var layerPresentation: ViewLayerPresentation {
        get { storedLayerPresentation }
        set {
            guard newValue != storedLayerPresentation else { return }
            storedLayerPresentation = newValue
            recordMutation(.style)
        }
    }

    /// Chainable variant for inline configuration. Corresponds to SwiftUI's
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
            damage: cachedPaintDamage,
            presentation: layerPresentation,
            shadow: shadow == .none ? nil : shadow
        )
    }

    @discardableResult
    package func recordMutation(_ domain: ViewDirtyDomain) -> UInt64 {
        let generation = uiContext.allocateGeneration()
        dirtyGenerations[domain] = generation
        if domain != .accessibility {
            storedMutationActionPolicies[domain] = uiContext.currentActionPolicy
        }
        var branch = self
        var ancestor = parentView
        while let current = ancestor {
            current.subtreeDirtyGenerations[domain] = generation
            current.dirtyChildViewIDs.insert(branch.id)
            branch = current
            ancestor = current.parentView
        }
        if domain == .geometry
            || domain == .scrolling
            || domain == .transform
            || domain == .structure
        {
            invalidateActiveTextInputGeometry()
        }
        return generation
    }

    private func invalidateActiveTextInputGeometry() {
        guard let window,
              let activeClient = window.textInputContext.activeClient,
              let activeView = activeClient as? View,
              activeView === self || activeView.isDescendant(of: self)
        else { return }
        window.textInputContext.invalidateState(for: activeClient)
    }

    public var stableHandle: Handle {
        Handle(view: self)
    }

    public var accessibilityValue: String? {
        get { storedAccessibilityProperties.value }
        set {
            guard newValue != storedAccessibilityProperties.value else {
                return
            }
            storedAccessibilityProperties.value = newValue
            recordMutation(.accessibility)
        }
    }

    // MARK: - Focus traversal

    /// Backs `isTabStop`. `nil` means "follow `acceptsFirstResponder`", so a
    /// control is in the tab order without being told to be, and a view that
    /// opts out stays opted out even if it later accepts first responder.
    var explicitTabStop: Bool?

    /// Exclude this view and everything under it from the tab order.
    ///
    /// One flag on a container rather than a flag on each descendant: a hidden
    /// panel, a collapsed section, or a disabled group leaves the order as a
    /// unit and rejoins it as a unit.
    public var excludesSubtreeFromTabOrder: Bool = false

    /// A stable identity for focus, surviving a subtree rebuild.
    ///
    /// Without this, focus is a reference to a view that a rebuild replaces —
    /// so typing in a search field that rebuilds its results would drop focus on
    /// every keystroke. With it, focus is restored by name to whatever view now
    /// occupies that role.
    public var focusKey: String?

    /// Marks a subtree as a focus group or modal focus boundary.
    public var focusScopeBehavior: FocusScopeBehavior = .none

    public var isFocused: Bool {
        window?.firstResponder === self
    }

    /// Called exactly once when this view gains or loses first-responder focus.
    open func focusStateDidChange() {
        recordMutation(.accessibility)
        setNeedsDisplay()
    }

    /// Whether the standard ring is added after this view draws.
    open var drawsFocusRing: Bool { acceptsFirstResponder }

    open func drawFocusRing(in context: GraphicsContext) {
        guard isFocused, drawsFocusRing,
              bounds.size.width > 0, bounds.size.height > 0
        else { return }
        var path = Path()
        path.addRoundedRect(
            Rect(
                x: 1,
                y: 1,
                width: max(0, bounds.size.width - 2),
                height: max(0, bounds.size.height - 2)),
            radius: max(2, cornerRadius))
        context.strokeColor = resolve(.role(.primary))
        context.lineWidth = 2
        context.stroke(path)
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

    /// Whether this view and its subtree participate in semantic hit testing.
    ///
    /// Drag previews disable this while remaining visible, so they cannot
    /// become their own drop target.
    public var isHitTestingEnabled: Bool {
        get { storedIsHitTestingEnabled }
        set { storedIsHitTestingEnabled = newValue }
    }

    /// Environment domains this view consumes.
    open var environmentDependencies: UIEnvironmentChanges {
        [.appearance, .increasedContrast]
    }

    open func environmentDidChange(_ changes: UIEnvironmentChanges) {
        if changes.contains(.appearance)
            || changes.contains(.increasedContrast)
        {
            viewDidChangeEffectiveAppearance()
        }
    }

    open func viewDidChangeEffectiveAppearance() {
        setNeedsDisplay()
    }

    open func viewDidChangeBackingScaleFactor() {
        setNeedsDisplay()
    }

    /// This view's natural unconstrained size. Reading it is side-effect free.
    open var intrinsicContentSize: Size { .zero }

    open func measure(_ constraints: LayoutConstraints) -> Size {
        constraints.constrain(intrinsicContentSize)
    }

    open func arrange(in rect: Rect) {
        if frame != rect { frame = rect }
        layoutIfNeeded()
    }

    open func invalidateIntrinsicContentSize() {
        intrinsicContentSizeNeedsUpdate = true
        setNeedsLayout()
        parentView?.setNeedsLayout()
    }

    open func setNeedsLayout() {
        guard !layoutNeedsUpdate else { return }
        layoutNeedsUpdate = true
        parentView?.markSubtreeNeedsLayout()
    }

    open func setNeedsDisplay() {
        setNeedsDisplay(bounds)
    }

    open func setNeedsDisplay(_ rect: Rect) {
        invalidateDisplay(rect)
    }

    open func layout() {}

    open func draw(in context: GraphicsContext) {
        _ = context
    }

    open override var nextResponder: Responder? {
        get {
            parentView
                ?? owningViewController
                ?? parentWindow
                ?? explicitNextResponder
        }
        set { setExplicitNextResponder(newValue) }
    }

    open func hitTest(_ point: Point) -> View? {
        semanticHitTest(point)
    }

}
