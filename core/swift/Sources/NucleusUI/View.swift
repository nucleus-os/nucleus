@_spi(NucleusCompositor) import NucleusLayers

@MainActor
open class View: Responder, Accessible, ~Sendable {
    public let id: ViewID
    public let accessibilityID: AccessibilityID
    package let uiContext: UIContext
    package let semanticLayerKind: LayerKind
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
    private var pendingDisplayDamage: Rect?
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
    package var animationRequests: [AnimationKeyPath: ViewAnimationRequest]
    package var animationHandles: [UInt64: AnimationHandle]
    package var currentAnimationHandleIDs: [AnimationKeyPath: UInt64]
    package var storedFadeTargetOpacity: Double?
    package var dirtyGenerations: ViewDirtyGenerations
    package var subtreeDirtyGenerations: ViewDirtyGenerations

    private var storedFrame: Rect
    private var storedIsHidden: Bool
    private var storedAlphaValue: Double
    private var storedBoundsOrigin: Point
    private var storedClipsToBounds: Bool
    private var storedShadow: Shadow

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
        self.animationRequests = [:]
        self.animationHandles = [:]
        self.currentAnimationHandleIDs = [:]
        self.storedFadeTargetOpacity = nil
        self.dirtyGenerations = ViewDirtyGenerations()
        self.subtreeDirtyGenerations = ViewDirtyGenerations()
        self.storedFrame = .zero
        self.storedIsHidden = false
        self.storedAlphaValue = 1
        self.storedBoundsOrigin = .zero
        self.storedClipsToBounds = false
        self.storedShadow = .none
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
        self.animationRequests = [:]
        self.animationHandles = [:]
        self.currentAnimationHandleIDs = [:]
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
        super.init()
        uiContext.registerEnvironmentConsumer(self)
    }

    isolated deinit {
        uiContext.unregisterEnvironmentConsumer(id)
        uiContext.cancelAnimations(owner: self)
        cancelOwnedAnimationHandles()
    }

    public func addSubview(_ child: View) {
        if child.parentView === self, childViews.last === child {
            return
        }
        precondition(
            child.uiContext === uiContext,
            "a view cannot adopt a child from another UIContext")
        child.detachFromSwiftTree()
        childViews.append(child)
        childViewsByID[child.id] = child
        childViewIndices[child.id] = childViews.count - 1
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
        return generation
    }

    public var stableHandle: Handle {
        Handle(view: self)
    }

    public var isAccessibilityElement: Bool {
        get { storedAccessibilityProperties.isElement }
        set {
            guard newValue != storedAccessibilityProperties.isElement else { return }
            storedAccessibilityProperties.isElement = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityLabel: String? {
        get { storedAccessibilityProperties.label }
        set {
            guard newValue != storedAccessibilityProperties.label else { return }
            storedAccessibilityProperties.label = newValue
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

    public var accessibilityHint: String? {
        get { storedAccessibilityProperties.hint }
        set {
            guard newValue != storedAccessibilityProperties.hint else { return }
            storedAccessibilityProperties.hint = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityValue: String? {
        get { storedAccessibilityProperties.value }
        set {
            guard newValue != storedAccessibilityProperties.value else { return }
            storedAccessibilityProperties.value = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityRole: AccessibilityRole? {
        get { storedAccessibilityProperties.role }
        set {
            guard newValue != storedAccessibilityProperties.role else { return }
            storedAccessibilityProperties.role = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityTraits: AccessibilityTraits {
        get { storedAccessibilityProperties.traits }
        set {
            guard newValue != storedAccessibilityProperties.traits else { return }
            storedAccessibilityProperties.traits = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityChildren: [any Accessible]? {
        get { storedAccessibilityChildren }
        set {
            storedAccessibilityChildren = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityProperties: AccessibilityProperties {
        get { storedAccessibilityProperties }
        set {
            guard newValue != storedAccessibilityProperties else { return }
            storedAccessibilityProperties = newValue
            recordMutation(.accessibility)
        }
    }

    /// Supplies semantic children that are not retained visual views.
    public var accessibilityVirtualChildrenProvider:
        (@MainActor () -> [AccessibilityVirtualElement])?
    {
        get { storedAccessibilityVirtualChildrenProvider }
        set {
            storedAccessibilityVirtualChildrenProvider = newValue
            recordMutation(.accessibility)
        }
    }

    public func setAccessibilityAction(
        _ action: AccessibilityAction,
        handler:
            @escaping @MainActor (AccessibilityActionRequest) -> Bool
    ) {
        storedAccessibilityActions[action] = handler
        recordMutation(.accessibility)
    }

    public func clearAccessibilityAction(_ action: AccessibilityAction) {
        guard storedAccessibilityActions.removeValue(forKey: action) != nil
        else { return }
        recordMutation(.accessibility)
    }

    public func postAccessibilityAnnouncement(
        _ announcement: String,
        priority: AccessibilityLiveRegion = .polite
    ) {
        guard !announcement.isEmpty else { return }
        uiContext.postAccessibilityNotification(
            AccessibilityNotification(
                kind: priority == .assertive ? .announcement : .liveRegion,
                target: accessibilityID,
                announcement: announcement))
    }

    package func detachFromSwiftTree(clearOwningViewController: Bool = true) {
        window?.windowScene?.cancelInputSequences(capturedBy: self)
        if let parentView {
            parentView.childViews.removeAll { $0 === self }
            parentView.childViewsByID[id] = nil
            parentView.reindexChildren()
            parentView.recordMutation(.structure)
            parentView.markSubtreeNeedsLayout()
            parentView.markSubtreeNeedsDisplay()
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

    package func reindexChildren() {
        childViewIndices.removeAll(keepingCapacity: true)
        childViewIndices.reserveCapacity(childViews.count)
        for (index, child) in childViews.enumerated() {
            childViewsByID[child.id] = child
            childViewIndices[child.id] = index
        }
    }

    package func isDescendant(of ancestor: View) -> Bool {
        var node = parentView
        while let current = node {
            if current === ancestor { return true }
            node = current.parentView
        }
        return false
    }

    package func defaultButton() -> Button? {
        if let button = self as? Button,
           button.isDefaultButton,
           button.isEnabled,
           !button.isHidden
        {
            return button
        }
        for child in childViews {
            if let button = child.defaultButton() { return button }
        }
        return nil
    }

    /// The window this view is installed in, found by walking up the view tree.
    /// `parentWindow` is only set on a window's root view, so a nested view has
    /// to climb. This matches `NSView.window` behavior.
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
    /// the nearest ancestor that specifies one, then from the owning
    /// `UIContext` environment.
    public var appearance: Appearance? {
        didSet {
            guard appearance != oldValue else { return }
            notifyEffectiveAppearanceChanged()
        }
    }

    /// Per-view palette override. `nil` inherits from the nearest ancestor that
    /// specifies one, then from the scene, then from the appearance's standard
    /// palette.
    ///
    /// Scoped rather than global. The reference keeps one process-wide palette
    /// and a global signal; scoping it means a preview swatch, or a surface that
    /// must stay legible against arbitrary wallpaper, can differ without
    /// pretending the whole shell retheme.
    public var palette: Palette? {
        didSet {
            guard palette != oldValue else { return }
            notifyEffectiveAppearanceChanged()
        }
    }

    /// The palette this view paints under.
    public var effectivePalette: Palette {
        var current: View? = self
        while let view = current {
            if let palette = view.palette { return palette }
            current = view.parentView
        }
        let base = parentWindow?.windowScene?.palette
            ?? Palette.standard(for: effectiveAppearance)
        return uiContext.environment.increasesContrast
            ? base.increasedContrast()
            : base
    }

    /// Resolve a spec against this view's palette. The call every `draw`
    /// makes — a view stores intent and resolves at paint time, which is what
    /// lets a retheme change the picture without touching the tree.
    public func resolve(_ spec: ColorSpec) -> Color {
        spec.resolve(in: effectivePalette)
    }

    /// Environment domains this view consumes.
    ///
    /// Appearance and contrast are the safe default because every custom view
    /// can call `resolve(_:)` and every focusable view can draw the framework
    /// focus ring. Subclasses add only the extra domains they actually consume.
    open var environmentDependencies: UIEnvironmentChanges {
        [.appearance, .increasedContrast]
    }

    open func environmentDidChange(
        _ changes: UIEnvironmentChanges
    ) {
        if changes.contains(.appearance)
            || changes.contains(.increasedContrast)
        {
            viewDidChangeEffectiveAppearance()
        }
    }

    /// Called when the appearance or palette this view paints under changes.
    ///
    /// Corresponds to `NSView.viewDidChangeEffectiveAppearance`. Overriding is for
    /// views holding *derived* state — a resolved colour cached on a sublayer.
    /// A view that resolves its specs in `draw` needs only the default repaint.
    open func viewDidChangeEffectiveAppearance() {
        setNeedsDisplay()
    }

    /// Notify this view and its subtree. Stops at any descendant that overrides
    /// the changed value, since nothing below it is affected.
    func notifyEffectiveAppearanceChanged() {
        viewDidChangeEffectiveAppearance()
        for child in childViews where child.palette == nil && child.appearance == nil {
            child.notifyEffectiveAppearanceChanged()
        }
    }

    /// The appearance this view actually paints under. Walks the parent
    /// chain to the nearest non-nil `appearance`, then uses the owning
    /// `UIContext` environment.
    public var effectiveAppearance: Appearance {
        var current: View? = self
        while let view = current {
            if let appearance = view.appearance {
                return appearance
            }
            current = view.parentView
        }
        return uiContext.environment.appearance
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
    private var storedGrowFactor: Double = 0
    public var growFactor: Double {
        get { storedGrowFactor }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedGrowFactor else { return }
            storedGrowFactor = value
            parentView?.setNeedsLayout()
        }
    }

    /// Share of a container's main-axis *overflow* this view gives back, weighted
    /// by measured size. `1` by default, so children shrink together rather than
    /// letting the last one overflow.
    private var storedShrinkFactor: Double = 1
    public var shrinkFactor: Double {
        get { storedShrinkFactor }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedShrinkFactor else { return }
            storedShrinkFactor = value
            parentView?.setNeedsLayout()
        }
    }

    /// Main-axis starting size, overriding the measured one. `nil` means measure.
    private var storedLayoutBasis: Double?
    public var layoutBasis: Double? {
        get { storedLayoutBasis }
        set {
            let value = newValue.map { $0.isFinite ? max(0, $0) : 0 }
            guard value != storedLayoutBasis else { return }
            storedLayoutBasis = value
            parentView?.setNeedsLayout()
        }
    }

    /// Minimum main-axis extent used by flex, stack, list, and grid containers.
    private var storedMinimumLayoutExtent: Double = 0
    public var minimumLayoutExtent: Double {
        get { storedMinimumLayoutExtent }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedMinimumLayoutExtent else { return }
            storedMinimumLayoutExtent = value
            if storedMaximumLayoutExtent < value {
                storedMaximumLayoutExtent = value
            }
            parentView?.setNeedsLayout()
        }
    }

    /// Maximum main-axis extent. Positive infinity means no upper bound.
    private var storedMaximumLayoutExtent: Double = .infinity
    public var maximumLayoutExtent: Double {
        get { storedMaximumLayoutExtent }
        set {
            let value: Double
            if newValue == .infinity {
                value = .infinity
            } else if newValue.isFinite {
                value = max(storedMinimumLayoutExtent, max(0, newValue))
            } else {
                value = storedMinimumLayoutExtent
            }
            guard value != storedMaximumLayoutExtent else { return }
            storedMaximumLayoutExtent = value
            parentView?.setNeedsLayout()
        }
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

    /// Invalidate a view-local region. Local damage is preserved through
    /// publication and rasterized under an outer clip when the recording is
    /// localizable. Runtime effects and backing-size changes automatically
    /// promote the update to a complete repaint.
    open func setNeedsDisplay(_ rect: Rect) {
        guard let damage = normalizedDisplayDamage(rect) else {
            return
        }
        if !displayNeedsUpdate {
            pendingDisplayDamage = damage
        } else if damage == .zero {
            pendingDisplayDamage = .zero
        } else if let pendingDisplayDamage,
                  pendingDisplayDamage != .zero
        {
            self.pendingDisplayDamage = pendingDisplayDamage.union(damage)
        }
        displayNeedsUpdate = true
        parentView?.markSubtreeNeedsDisplay()
    }

    /// Convert an AppKit-shaped bounds-space invalidation to the zero-origin
    /// backing coordinates used by paint textures. A complete-bounds request
    /// returns `nil`; `.zero` is the sentinel used internally for that case
    /// while a display pass is pending.
    private func normalizedDisplayDamage(_ rect: Rect) -> Rect? {
        guard rect.isFinite, !rect.isEmpty,
              bounds.isFinite, !bounds.isEmpty
        else {
            return nil
        }
        let left = max(rect.origin.x, bounds.origin.x)
        let top = max(rect.origin.y, bounds.origin.y)
        let right = min(
            rect.origin.x + rect.size.width,
            bounds.origin.x + bounds.size.width)
        let bottom = min(
            rect.origin.y + rect.size.height,
            bounds.origin.y + bounds.size.height)
        guard right > left, bottom > top else { return nil }
        let clipped = Rect(
            x: left - bounds.origin.x,
            y: top - bounds.origin.y,
            width: right - left,
            height: bottom - top)
        if clipped.origin == .zero, clipped.size == bounds.size {
            // A zero rect distinguishes complete damage from an invalid/no-op
            // request while `displayNeedsUpdate` is true.
            return .zero
        }
        return clipped
    }

    open func layout() {
    }

    /// Draw this view's content. The framework paints `style` underneath
    /// first, so an override adds to the styled background rather than
    /// replacing it.
    ///
    /// Nucleus records the complete drawing each time, then replays it under the
    /// invalidated local clip while preserving unchanged backing pixels. This
    /// keeps the immediate drawing contract deterministic and avoids requiring
    /// subclasses to branch on a dirty rectangle.
    open func draw(in context: GraphicsContext) {
        _ = context
    }

    /// Run layout over the dirty part of this subtree. Clean subtrees are
    /// skipped outright: with a per-frame layout pass over a whole shell, walking
    /// every view to discover that nothing changed is the dominant cost.
    public func layoutIfNeeded() {
        var work: [View] = [self]
        while let view = work.popLast() {
            guard view.layoutNeedsUpdate || view.subtreeLayoutNeedsUpdate else {
                continue
            }
            if view.layoutNeedsUpdate {
                view.layoutNeedsUpdate = false
                view.intrinsicContentSizeNeedsUpdate = false
                view.layout()
            }
            // Cleared before descending: `layout()` places children, which
            // re-marks this flag through their frame setters, and those children
            // are exactly the nodes queued below.
            view.subtreeLayoutNeedsUpdate = false
            for child in view.childViews.reversed() {
                work.append(child)
            }
        }
    }

    public func displayIfNeeded() {
        var work: [View] = [self]
        while let view = work.popLast() {
            guard view.displayNeedsUpdate || view.subtreeDisplayNeedsUpdate
            else {
                continue
            }
            if view.displayNeedsUpdate {
                let requestedDamage = view.pendingDisplayDamage
                view.displayNeedsUpdate = false
                view.pendingDisplayDamage = nil
                let context = GraphicsContext()
                view.storedStyle.draw(in: context, bounds: view.bounds)
                view.draw(in: context)
                view.drawFocusRing(in: context)
                let recording = context.recording
                if recording != view.cachedRecording {
                    view.cachedRecording = recording
                    view.cachedPaintDamage =
                        requestedDamage == .zero ? nil : requestedDamage
                    view.recordMutation(.content)
                }
            }
            view.subtreeDisplayNeedsUpdate = false
            for child in view.childViews.reversed() {
                work.append(child)
            }
        }
    }

    open override var nextResponder: Responder? {
        get { parentView ?? owningViewController ?? parentWindow ?? explicitNextResponder }
        set { setExplicitNextResponder(newValue) }
    }

    /// Hit-test `event.location` in this subtree and deliver the event to the
    /// view found, then up its responder chain. The location is rebased into
    /// each view's own coordinates on the way down.
    ///
    /// This is single-tree dispatch with no pointer capture. `WindowScene`
    /// dispatch adds capture and enter/exit tracking, which need scene-wide
    /// state; a view alone cannot know the pointer left it for a sibling.
    /// Convert `point` from `view`'s coordinate system into this view's.
    /// A `nil` view means window coordinates. Corresponds to `NSView.convert(_:from:)`.
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

    /// Convert a rectangle, as the bounding box of its converted corners.
    ///
    /// All four corners, not the origin and the size: under a rotation or a
    /// scale a rectangle does not map to a rectangle of the same size, and
    /// passing the size through unchanged — which this used to do — cannot
    /// express either.
    public func convert(_ rect: Rect, from view: View?) -> Rect {
        View.boundingBox(rect.corners.map { convert($0, from: view) })
    }

    public func convert(_ rect: Rect, to view: View?) -> Rect {
        View.boundingBox(rect.corners.map { convert($0, to: view) })
    }

    static func boundingBox(_ points: [Point]) -> Rect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A point in this view's own coordinates, from its parent's.
    ///
    /// **The single definition of the step between a view and its parent.** It
    /// used to be open-coded in four places — `hitTest`, both window-space
    /// walks, and `dispatchEvent` — and they drifted: none of them applied
    /// `transform`, so a scaled or rotated view drew transformed and hit-tested
    /// untransformed.
    ///
    /// The transform is applied about the anchor point, matching the renderer,
    /// which composes `translate(position) · pivot · transform · unpivot`. The
    /// anchor is the layer default of (0.5, 0.5), so a view scales about its
    /// own centre — the Core Animation convention, and the one the compositor
    /// is already using to draw.
    func convertFromParent(_ point: Point) -> Point {
        let ownFrame = frame
        var local = Point(x: point.x - ownFrame.origin.x, y: point.y - ownFrame.origin.y)

        if let inverse = transformAboutAnchor()?.inverted() {
            local = inverse.apply(local)
        }
        return Point(x: local.x + boundsOrigin.x, y: local.y + boundsOrigin.y)
    }

    /// A point in this view's parent's coordinates, from its own. The exact
    /// inverse of `convertFromParent`.
    func convertToParent(_ point: Point) -> Point {
        var local = Point(x: point.x - boundsOrigin.x, y: point.y - boundsOrigin.y)
        if let transform = transformAboutAnchor() {
            local = transform.apply(local)
        }
        let ownFrame = frame
        return Point(x: local.x + ownFrame.origin.x, y: local.y + ownFrame.origin.y)
    }

    /// This view's transform, expressed about its anchor point rather than its
    /// origin. `nil` when there is nothing to apply, which is the common case
    /// and skips the work entirely.
    private func transformAboutAnchor() -> AffineTransform? {
        let transform = storedTransform
        guard transform != .identity else { return nil }

        let affine = transform.affine2D
        let size = frame.size
        let anchorX = size.width * View.anchorPoint.x
        let anchorY = size.height * View.anchorPoint.y
        // `concatenating(other)` is "self after other", so this reads
        // right-to-left: move the anchor to the origin, transform, move it back.
        return AffineTransform.translation(x: anchorX, y: anchorY)
            .concatenating(affine)
            .concatenating(AffineTransform.translation(x: -anchorX, y: -anchorY))
    }

    /// The anchor every view transforms about. Fixed rather than per-view: the
    /// layer model's default, and nothing has yet needed to vary it.
    static let anchorPoint = Point(x: 0.5, y: 0.5)

    /// Up the tree, one `convertToParent` per level.
    private func convertToWindowSpace(_ point: Point) -> Point {
        var result = point
        var node: View? = self
        while let current = node {
            result = current.convertToParent(result)
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
            result = current.convertFromParent(result)
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
        let localInSelf = convertFromParent(event.location)
        let local = target.convert(localInSelf, from: self)
        return target.deliverEvent(event.relocated(to: local))
    }

    open func hitTest(_ point: Point) -> View? {
        guard !isHidden else {
            return nil
        }

        // A transform that collapses the plane has no preimage. The view is
        // drawn as nothing, so nothing hits it — whereas falling back to the
        // untransformed mapping would make an invisible view swallow input
        // across its whole frame.
        if let transform = transformAboutAnchor(), transform.inverted() == nil {
            return nil
        }

        // Map into this view's own coordinates *first*, then test. Testing the
        // frame in the parent's space would be testing an axis-aligned box that
        // a rotated view does not occupy.
        let localPoint = convertFromParent(point)
        guard bounds.contains(localPoint) else {
            return nil
        }

        for child in childViews.reversed() {
            if let hit = child.hitTest(localPoint) {
                return hit
            }
        }
        return self
    }
}
