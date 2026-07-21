import NucleusLayers
import Tracy

@MainActor
public struct WindowHitTestResult {
    public let window: Window
    public let view: View
}

public enum SceneActivationState: Sendable, Equatable {
    case background
    case inactive
    case active
    case disconnected
}

@MainActor
public final class WindowScene: ~Sendable {
    private let publisher: WindowLayerPublisher
    private struct PublicationRecord {
        var level: WindowLevel
        var sequence: Int
        var content: PublishedVisualContent
    }

    package let visualContext: Context
    public let uiContext: UIContext
    public private(set) var windows: [Window] = []
    public private(set) var keyWindow: Window?
    public private(set) var activationState: SceneActivationState = .background
    public private(set) var menuPresentation:
        MenuPresentationController? = nil
    public lazy var accessibilityTree = AccessibilityTree(scene: self)

    /// Called after the host changes this retained scene's activation state.
    public var onActivationChange:
        (@MainActor (SceneActivationState) -> Void)?

    private enum SequenceKind: Hashable {
        case pointer
        case touch
    }

    private struct SequenceKey: Hashable {
        var kind: SequenceKind
        var deviceID: InputDeviceID
        var sequenceID: InputSequenceID
    }

    private final class CaptureRecord {
        weak var window: Window?
        weak var view: View?
        var lastSceneLocation: Point

        init(window: Window, view: View, lastSceneLocation: Point) {
            self.window = window
            self.view = view
            self.lastSceneLocation = lastSceneLocation
        }
    }

    /// Independent capture per pointer/touch sequence.
    private var captures: [SequenceKey: CaptureRecord] = [:]
    package var activeDragSession: DragSession?
    /// The view the pointer is currently over, for enter/exit.
    private weak var trackedView: View?

    /// Views currently marked hovered, outermost first. Held strongly for the
    /// duration of a hover so an exit always reaches what was entered, even if
    /// the tree drops the view meanwhile.
    private var hoveredViews: [View] = []

    /// The tracking area under the pointer, and when the pointer arrived on it.
    private var activeTrackingArea: TrackingArea?
    private var hoverBeganAtNanoseconds: UInt64 = 0
    private var toolTipShown = false

    /// How long the pointer must rest before a tooltip appears.
    public var toolTipDelayNanoseconds: UInt64 = 500_000_000

    /// The cursor the current hover resolves to. The shell reads this and hands
    /// it to the compositor; NucleusUI owns the decision, not the pixels.
    public private(set) var cursor: Cursor = .arrow

    /// Called when `cursor` changes, so a host can push it without polling.
    public var onCursorChange: ((Cursor) -> Void)?

    /// Called when a tooltip should appear or disappear. `nil` hides.
    ///
    /// The point is in scene coordinates: the anchor the tooltip positions
    /// against, which is the tracked area's frame rather than the pointer, so a
    /// tooltip does not jitter as the pointer moves within a widget.
    public var onToolTipChange: ((String?, Rect) -> Void)?

    package init(
        windows: [Window] = [],
        uiContext: UIContext,
        visualContext: Context
    ) {
        precondition(
            uiContext.resourceHostHandle == 0
                || uiContext.resourceHostHandle
                    == visualContext.commitSink.resourceHostHandle,
            "WindowScene semantic and visual contexts use different resource hosts")
        precondition(
            uiContext.runtimeHost === visualContext.runtimeHost,
            "WindowScene semantic and visual contexts use different runtime hosts")
        self.uiContext = uiContext
        self.visualContext = visualContext
        self.publisher = WindowLayerPublisher(context: visualContext)
        for window in windows {
            addWindow(window)
        }
    }

    /// Explicit in-memory scene for tests, previews, and measurement tools.
    ///
    /// Production hosts construct scenes through their embedder/app-host
    /// context so no production call silently acquires this sink.
    public convenience init(inMemoryWindows windows: [Window] = []) {
        let runtimeHost = windows.first?.uiContext.runtimeHost
            ?? LayerRuntimeHost.inMemory()
        let visualContext = Application.makeInMemoryVisualContext(
            runtimeHost: runtimeHost)
        self.init(
            windows: windows,
            uiContext: windows.first?.uiContext
                ?? UIContext(
                    services: .inMemory(),
                    runtimeHost: runtimeHost),
            visualContext: visualContext)
    }

    public func addWindow(_ window: Window) {
        precondition(
            activationState != .disconnected,
            "a disconnected WindowScene cannot adopt a window")
        guard !windows.contains(where: { $0 === window }) else {
            return
        }
        precondition(
            window.uiContext === uiContext,
            "a WindowScene cannot adopt a window from another UIContext")
        windows.append(window)
        window.windowScene = self
    }

    /// Apply a lifecycle transition authored by the platform host.
    ///
    /// Disconnect is a throwing teardown operation because it first removes the
    /// published visual tree. Use `disconnect()` for that terminal transition.
    public func transition(to state: SceneActivationState) {
        precondition(
            state != .disconnected,
            "use WindowScene.disconnect() for terminal teardown")
        guard activationState != .disconnected else { return }
        guard activationState != state else { return }
        activationState = state
        if state == .inactive || state == .background {
            resignKey()
        }
        onActivationChange?(state)
    }

    /// Terminal, idempotent scene teardown.
    ///
    /// The visual publisher is invalidated before semantic ownership is
    /// released, so registered content and layers cannot outlive the scene that
    /// authored them. A host destroys its protocol surface after this returns.
    public func disconnect() throws(UIError) {
        guard activationState != .disconnected else { return }
        cancelDrag()
        menuPresentation?.sceneDidDisconnect()
        try publisher.invalidate()
        resignKey()
        hideToolTip()
        dismissAllPopovers()
        for view in hoveredViews {
            view.isHovered = false
        }
        hoveredViews.removeAll(keepingCapacity: false)
        trackedView = nil
        activeTrackingArea = nil
        hoverBeganAtNanoseconds = 0
        toolTipShown = false
        popoverFocusRestorations.removeAll(keepingCapacity: false)
        for window in windows {
            window.root?.notifyRetainedHierarchyWillDetach()
            window.windowScene = nil
            window.setOrderedOut()
        }
        windows.removeAll(keepingCapacity: false)
        activationState = .disconnected
        let activationCallback = onActivationChange
        onActivationChange = nil
        onCursorChange = nil
        onToolTipChange = nil
        activationCallback?(.disconnected)
    }

    public func windowPoint(_ point: Point, in window: Window) -> Point {
        window.windowPoint(fromScene: point)
    }

    public func scenePoint(_ point: Point, in window: Window) -> Point {
        window.scenePoint(fromWindow: point)
    }

    public func windowRect(_ rect: Rect, in window: Window) -> Rect {
        window.windowRect(fromScene: rect)
    }

    public func sceneRect(_ rect: Rect, in window: Window) -> Rect {
        window.sceneRect(fromWindow: rect)
    }

    @discardableResult
    public func removeWindow(_ window: Window) -> Bool {
        guard windows.contains(where: { $0 === window }) else {
            return false
        }
        cancelInputSequences(in: window)
        window.root?.notifyRetainedHierarchyWillDetach()
        windows.removeAll { $0 === window }
        if window.windowScene === self {
            window.windowScene = nil
        }
        if keyWindow === window {
            keyWindow = nil
            window.setKey(false)
        }
        window.setOrderedOut()
        return true
    }

    public func orderFront(_ window: Window) {
        addWindow(window)
        windows.removeAll { $0 === window }
        windows.append(window)
        window.setVisible(true)
    }

    public func orderOut(_ window: Window) {
        cancelInputSequences(in: window)
        window.setOrderedOut()
        if keyWindow === window {
            keyWindow = nil
        }
    }

    public func makeKey(_ window: Window) {
        addWindow(window)
        keyWindow?.setKey(false)
        keyWindow = window
        window.setKey(true)
    }

    /// Give up key status entirely, leaving the scene with no key window.
    ///
    /// The counterpart to `makeKey`. Keyboard focus genuinely leaves a scene —
    /// `wl_keyboard.leave` for a client, a compositor handing the seat
    /// elsewhere — and without this the scene would keep routing keys to a
    /// window that no longer has focus. Any pointer capture is released too: the
    /// press that took it can no longer be completed.
    public func resignKey() {
        keyWindow?.setKey(false)
        keyWindow = nil
        cancelInputSequences()
    }

    /// The scene's root layer, created and attached on first use. An embedder
    /// attaching its own content parents it here.
    package func ensureRootAttached() throws(UIError) -> Layer {
        guard activationState != .disconnected else {
            throw .invalidArgument(
                detail: "a disconnected WindowScene cannot attach visuals")
        }
        return try publisher.ensureRootAttached()
    }

    package var publishedVisualLayerCount: Int {
        publisher.publishedVisualLayerCount
    }

    package var retainedPaintRegistrationCount: Int {
        publisher.retainedPaintRegistrationCount
    }

    /// The sublayer index at which embedder-owned content at `level` should be
    /// inserted under the scene's root, so it lands above the scene's own
    /// windows at or below that level.
    ///
    /// The scene answers *where*; the embedder does the attaching, because what
    /// it is attaching is its own concept.
    package func insertionIndex(forLevel level: WindowLevel) -> UInt32 {
        let precedingWindowCount = windowsForDisplay().filter { window in
            window.isVisible &&
                window.root != nil &&
                window.level.rawValue <= level.rawValue
        }.count
        return UInt32(precedingWindowCount)
    }

    package func publish() throws(UIError) -> PublishedScene {
        try publish { _ in true }
    }

    package func publish(
        includes windowIncluded: @MainActor (Window) -> Bool
    ) throws(UIError) -> PublishedScene {
        guard activationState != .disconnected else {
            throw .invalidArgument(
                detail: "a disconnected WindowScene cannot publish")
        }
        let traceZone = Trace.beginZone("nucleus.window_scene.publish", color: Trace.Color.blue)
        defer {
            traceZone.end()
        }
        let displayWindows = windowsForDisplay()
        Trace.plot("swift.nucleus.window_scene.windows", UInt64(displayWindows.count))
        let visualContent = try publisher.publish(
            windows: displayWindows,
            includes: windowIncluded
        )
        return PublishedScene(visualContent: visualContent)
    }

    package func publishPlacing(
        _ placements: [ScenePlacement]
    ) throws(UIError) -> PublishedScene {
        try publishPlacing(placements) { _ in true }
    }

    /// Publish this scene's windows interleaved with embedder-owned content by
    /// window level. The scene does not know what a placement *is* — only where
    /// it sorts — which is what keeps compositor concepts like hosted client
    /// surfaces out of the UI framework.
    /// Named distinctly from `publish` so `NucleusUIEmbedder`'s public
    /// `publish(placing:includes:)` forwards here rather than shadowing itself.
    /// A same-signature forwarding extension recurses silently — it compiles,
    /// and it dies at run time.
    package func publishPlacing(
        _ placements: [ScenePlacement],
        includes windowIncluded: @MainActor (Window) -> Bool
    ) throws(UIError) -> PublishedScene {
        guard activationState != .disconnected else {
            throw .invalidArgument(
                detail: "a disconnected WindowScene cannot publish")
        }
        let displayWindows = windowsForDisplay().filter { window in
            windowIncluded(window) && window.isVisible && window.root != nil
        }
        Trace.plot("swift.nucleus.window_scene.windows", UInt64(displayWindows.count))
        let windowContent = try publisher.publish(windows: displayWindows)
        let windowRecords = zip(displayWindows, windowContent).enumerated().map { index, pair in
            PublicationRecord(level: pair.0.level, sequence: index * 2, content: pair.1)
        }
        let placedRecords = placements.filter(\.visible).enumerated().map { index, placement in
            PublicationRecord(
                level: placement.level,
                sequence: index * 2 + 1,
                content: PublishedVisualContent(
                    id: placement.id,
                    rootLayerID: placement.rootLayerID,
                    orderIndex: 0,
                    visible: placement.visible
                )
            )
        }
        let ordered = (windowRecords + placedRecords).sorted { lhs, rhs in
            if lhs.level.rawValue != rhs.level.rawValue {
                return lhs.level.rawValue < rhs.level.rawValue
            }
            return lhs.sequence < rhs.sequence
        }
        let visualContent = ordered.enumerated().map { index, record in
            var content = record.content
            content.orderIndex = UInt32(index)
            return content
        }
        return PublishedScene(visualContent: visualContent)
    }

    // MARK: - Event dispatch

    /// Route an event into the scene and return whether anything handled it.
    ///
    /// Two routes, as in AppKit. Keyboard-like events go to the key window's
    /// first responder and up its chain, ignoring the pointer entirely. Pointer
    /// events hit-test to a view and then traverse *that* view's chain. A
    /// capture, if one is active, overrides the hit test so a drag that leaves
    /// the pressed view keeps reaching it.
    @discardableResult
    public func dispatchEvent(_ event: Event) -> EventHandling {
        guard activationState != .disconnected else {
            return .notHandled
        }
        if let menuPresentation {
            return menuPresentation.handleEvent(event)
        }
        // Dismissal comes first: a click that closes a menu must not also press
        // whatever was underneath it.
        if applyPopoverDismissal(event) { return .handled }

        if activeDragSession != nil {
            switch event.type {
            case .pointerMoved, .pointerDragged, .touchMoved:
                _ = updateDrag(at: event.location)
                return .handled
            case .pointerUp, .touchUp:
                dropFromInput(at: event.location)
                return .handled
            case .pointerCancelled, .touchCancelled:
                cancelDrag()
                return .handled
            default:
                break
            }
        }

        if event.isKeyEvent {
            guard let keyWindow else { return .notHandled }
            // Tab moves focus before anything sees it. A focused text field
            // would otherwise insert a tab character and focus would never
            // leave it.
            if keyWindow.handleFocusTraversal(event) == .handled { return .handled }
            return keyWindow.deliverKeyEvent(event)
        }

        if let key = sequenceKey(for: event),
           eventContinuesCapturedSequence(event),
           let capture = captures[key]
        {
            guard let window = capture.window, let view = capture.view else {
                captures[key] = nil
                return .notHandled
            }
            capture.lastSceneLocation = event.location
            if event.type == .pointerDragged
                || event.type == .touchMoved,
                beginConfiguredDrag(
                    startingAt: view,
                    sceneLocation: event.location)
            {
                captures[key] = nil
                return .handled
            }
            let hit = WindowHitTestResult(window: window, view: view)
            let local = convert(event.location, toViewIn: hit)
            let route = view.deliverEventRoute(event.relocated(to: local))
            if eventEndsSequence(event) {
                captures[key] = nil
            }
            return normalized(route.handling)
        }

        guard let hit = hitTest(at: event.location) else {
            // Nothing under the pointer: whatever was hovered no longer is.
            updateHover(nil, event: event)
            return .notHandled
        }
        let localEvent = event.relocated(to: convert(event.location, toViewIn: hit))

        if event.type == .pointerDragged
            || event.type == .touchMoved,
            beginConfiguredDrag(
                startingAt: hit.view,
                sceneLocation: event.location)
        {
            return .handled
        }

        if event.type == .pointerDown, event.button == .right,
           let menu = contextMenu(startingAt: hit.view)
        {
            let anchor = Rect(
                x: event.location.x,
                y: event.location.y,
                width: 1,
                height: 1)
            present(
                menu,
                anchor: anchor,
                stickyOpeningGesture: true)
            return .handled
        }

        if event.type != .touchDown && event.type != .touchMoved
            && event.type != .touchUp && event.type != .touchCancelled
        {
            updateTrackedView(hit.view, event: localEvent)
            updateHover(hit, event: event)
        }
        let route = hit.view.deliverEventRoute(localEvent)
        if eventBeginsSequence(event),
           route.handling != .notHandled,
           let key = sequenceKey(for: event)
        {
            let capturedView = route.responder as? View ?? hit.view
            captures[key] = CaptureRecord(
                window: hit.window,
                view: capturedView,
                lastSceneLocation: event.location)
        }
        return normalized(route.handling)
    }

    /// Give up every pointer capture without delivering cancellation.
    public func releasePointerCapture() {
        captures = captures.filter { $0.key.kind != .pointer }
    }

    /// Cancel every captured input sequence. Hosts call this on surface leave
    /// and teardown; cancellation clears control state before references drop.
    public func cancelInputSequences() {
        cancelInputSequences(where: { _ in true })
    }

    public func cancelInputSequences(for deviceID: InputDeviceID) {
        cancelInputSequences { $0.key.deviceID == deviceID }
    }

    package func cancelInputSequences(capturedBy subtree: View) {
        cancelInputSequences { entry in
            guard let captured = entry.value.view else { return true }
            return captured === subtree || captured.isDescendant(of: subtree)
        }
    }

    private func cancelInputSequences(in window: Window) {
        cancelInputSequences { $0.value.window === window }
    }

    private func cancelInputSequences(
        where shouldCancel: ((key: SequenceKey, value: CaptureRecord)) -> Bool
    ) {
        let victims = captures.filter(shouldCancel)
        for (key, record) in victims {
            captures[key] = nil
            guard let window = record.window, let view = record.view else {
                continue
            }
            let hit = WindowHitTestResult(window: window, view: view)
            let local = convert(record.lastSceneLocation, toViewIn: hit)
            var event = Event(
                type: key.kind == .pointer
                    ? .pointerCancelled
                    : .touchCancelled,
                location: local,
                deviceID: key.deviceID,
                sequenceID: key.sequenceID)
            event.activeButtons = []
            _ = view.deliverEvent(event)
        }
    }

    private func sequenceKey(for event: Event) -> SequenceKey? {
        switch event.type {
        case .pointerDown, .pointerDragged, .pointerUp, .pointerCancelled:
            SequenceKey(
                kind: .pointer,
                deviceID: event.deviceID,
                sequenceID: event.sequenceID)
        case .touchDown, .touchMoved, .touchUp, .touchCancelled:
            SequenceKey(
                kind: .touch,
                deviceID: event.deviceID,
                sequenceID: event.sequenceID)
        default:
            nil
        }
    }

    private func eventBeginsSequence(_ event: Event) -> Bool {
        event.type == .pointerDown || event.type == .touchDown
    }

    private func eventContinuesCapturedSequence(_ event: Event) -> Bool {
        switch event.type {
        case .pointerDragged, .pointerUp, .pointerCancelled,
             .touchMoved, .touchUp, .touchCancelled:
            true
        default:
            false
        }
    }

    private func eventEndsSequence(_ event: Event) -> Bool {
        switch event.type {
        case .pointerUp, .pointerCancelled, .touchUp, .touchCancelled:
            true
        default:
            false
        }
    }

    private func normalized(_ handling: EventHandling) -> EventHandling {
        handling == .capture ? .handled : handling
    }

    private func contextMenu(startingAt view: View) -> Menu? {
        var node: View? = view
        while let current = node {
            if let provider = current.contextMenuProvider {
                return provider()
            }
            node = current.parentView
        }
        return nil
    }

    /// Send enter/exit as the pointer crosses view boundaries, so a control can
    /// un-highlight when the pointer leaves it.
    private func updateTrackedView(_ view: View, event: Event) {
        guard trackedView !== view else { return }
        if let previous = trackedView {
            var exit = event
            exit.type = .pointerExited
            _ = previous.deliverEvent(exit)
        }
        trackedView = view
        var enter = event
        enter.type = .pointerEntered
        _ = view.deliverEvent(enter)
    }

    // MARK: - Popovers

    /// Open popovers, oldest first. A stack rather than one slot: a menu opens a
    /// submenu, and dismissing the parent has to take the child with it.
    public private(set) var popovers: [Popover] = []

    private final class PopoverFocusRestoration {
        weak var window: Window?
        weak var responder: Responder?

        init(window: Window?, responder: Responder?) {
            self.window = window
            self.responder = responder
        }
    }

    private var popoverFocusRestorations:
        [ObjectIdentifier: PopoverFocusRestoration] = [:]

    /// The palette every window in this scene paints under, unless a view
    /// overrides it.
    ///
    /// Assigning retheme the whole scene: each root is notified, and any view
    /// resolving `ColorSpec`s in `draw` repaints with the new colours without
    /// being rebuilt.
    public var palette: Palette? {
        didSet {
            guard palette != oldValue else { return }
            for window in windows {
                window.root?.notifyEffectiveAppearanceChanged()
            }
        }
    }

    /// The area popovers are placed within — the display, in scene coordinates.
    /// Set by the host once the output geometry is known.
    public var displayBounds: Rect = .zero {
        didSet {
            guard displayBounds != oldValue else { return }
            for popover in popovers { popover.place(in: displayBounds) }
            menuPresentation?.displayBoundsDidChange()
        }
    }

    /// Present one retained desktop menu. A scene owns at most one menu
    /// presentation; opening another terminally cancels the prior cascade.
    @discardableResult
    public func present(
        _ menu: Menu,
        anchor: Rect,
        preferring edge: PopupEdge = .below,
        level: WindowLevel = .overlay,
        stickyOpeningGesture: Bool = false,
        onFinish:
            (@MainActor (MenuPresentationResult) -> Void)? = nil
    ) -> MenuPresentationController {
        precondition(
            activationState != .disconnected,
            "a disconnected WindowScene cannot present a menu")
        menuPresentation?.dismiss()
        let controller = MenuPresentationController(
            menu: menu,
            scene: self,
            anchor: anchor,
            preferredEdge: edge,
            level: level,
            stickyOpeningGesture: stickyOpeningGesture,
            onFinish: onFinish)
        menuPresentation = controller
        controller.begin()
        return controller
    }

    package func menuPresentationDidFinish(
        _ presentation: MenuPresentationController
    ) {
        if menuPresentation === presentation {
            menuPresentation = nil
        }
    }

    /// Show a popover, placing it against its anchor and ordering it in.
    public func present(_ popover: Popover) {
        popover.place(in: displayBounds)
        popovers.append(popover)
        addWindow(popover.window)
        popover.window.orderFront()
        if popover.focusBehavior == .key {
            popoverFocusRestorations[ObjectIdentifier(popover)] =
                PopoverFocusRestoration(
                    window: keyWindow,
                    responder: keyWindow?.firstResponder)
            makeKey(popover.window)
            _ = popover.window.makeFirstResponder(
                popover.window.root?.firstTabStop())
        }
    }

    /// Dismiss `popover` and everything opened on top of it.
    ///
    /// The cascade is the point: a submenu whose parent has gone is orphaned
    /// chrome that nothing can dismiss.
    public func dismiss(_ popover: Popover) {
        guard let index = popovers.firstIndex(where: { $0 === popover }) else { return }
        let victims = Array(popovers[index...])
        popovers.removeSubrange(index...)
        for victim in victims.reversed() {
            victim.window.orderOut()
            _ = removeWindow(victim.window)
            restoreFocus(after: victim)
            victim.onDismiss?()
        }
    }

    private func restoreFocus(after popover: Popover) {
        guard let restoration = popoverFocusRestorations.removeValue(
            forKey: ObjectIdentifier(popover))
        else { return }
        guard let window = restoration.window,
              windows.contains(where: { $0 === window }),
              window.isVisible
        else {
            keyWindow = nil
            return
        }
        makeKey(window)
        if let responder = restoration.responder {
            _ = window.makeFirstResponder(responder)
        }
    }

    public func dismissAllPopovers() {
        if let menuPresentation {
            menuPresentation.dismiss()
        }
        guard let first = popovers.first else { return }
        dismiss(first)
    }

    /// Apply the dismissal policies to an event. Returns whether the event was
    /// consumed by a dismissal, in which case it must not also reach a view: a
    /// click that closes a menu should not press whatever was underneath it.
    private func applyPopoverDismissal(_ event: Event) -> Bool {
        guard !popovers.isEmpty else { return false }

        if event.type == .keyDown && event.keyCode == .escape {
            if let target = popovers.last(where: {
                $0.dismissal.contains(.escapeKey)
            }) {
                dismiss(target)
                return true
            }
        }

        guard event.type == .pointerDown else { return false }

        // Passive dismissals first, and they never consume: a tooltip describes
        // what is under the pointer, so the click it cancels must still reach
        // it. Movement is *not* a dismissal — hover tracking already retires a
        // tooltip when the pointer leaves its area, and dismissing on any motion
        // would kill it on the first jitter.
        for target in popovers where target.dismissal.contains(.anyClickPassively) {
            dismiss(target)
        }

        let inside = hitTest(at: event.location).map { hit in
            popovers.contains { $0.window === hit.window }
        } ?? false
        guard !inside else { return false }

        if let target = popovers.first(where: {
            $0.dismissal.contains(.outsideClick)
        }) {
            dismiss(target)
            return true
        }

        return false
    }

    // MARK: - Hover, cursor, and tooltips

    /// Recompute the hover state for the pointer's current position.
    ///
    /// Hover is a *chain*, not a single view: a widget stays hovered while the
    /// pointer is over the label inside it, because both have tracking areas
    /// containing the point. A bar widget that lit up only when the pointer
    /// missed its own text would be useless.
    private func updateHover(_ hit: WindowHitTestResult?, event: Event) {
        let chain = hit.map { hoverChain(for: $0, at: event.location) } ?? []
        let entered = chain.map(\.view)

        for view in hoveredViews where !entered.contains(where: { $0 === view }) {
            view.isHovered = false
        }
        for view in entered where !view.isHovered {
            view.isHovered = true
        }
        hoveredViews = entered

        // The innermost area wins: it is the most specific thing under the
        // pointer.
        let area = chain.last?.area
        if area !== activeTrackingArea {
            activeTrackingArea = area
            hoverBeganAtNanoseconds = event.timestampNanoseconds
            if toolTipShown {
                toolTipShown = false
                hideToolTip()
                onToolTipChange?(nil, .zero)
            }
        }

        updateCursor(chain)
    }

    /// Views from outermost to innermost whose tracking areas contain the
    /// pointer, paired with the area that matched.
    private func hoverChain(
        for hit: WindowHitTestResult, at scenePoint: Point
    ) -> [(view: View, area: TrackingArea)] {
        let inWindow = hit.window.windowPoint(fromScene: scenePoint)

        var result: [(view: View, area: TrackingArea)] = []
        var node: View? = hit.view
        while let current = node {
            let local = current.convert(inWindow, from: nil)
            if let area = current.trackingArea(at: local) {
                result.append((current, area))
            }
            node = current.parentView
        }
        return result.reversed()
    }

    /// The cursor is the innermost area that names one; an area with no cursor
    /// inherits rather than resetting to the arrow.
    private func updateCursor(_ chain: [(view: View, area: TrackingArea)]) {
        let resolved = chain.reversed().compactMap(\.area.cursor).first ?? .arrow
        guard resolved != cursor else { return }
        cursor = resolved
        onCursorChange?(resolved)
    }

    /// Advance the tooltip timer. A host calls this each frame with the current
    /// time; a tooltip must appear while the pointer is *not* moving, so it
    /// cannot be driven by events alone.
    ///
    /// Idempotent — calling it repeatedly after a tooltip has appeared does
    /// nothing.
    public func updateToolTip(atNanoseconds now: UInt64) {
        guard !toolTipShown, let area = activeTrackingArea else { return }
        guard now &- hoverBeganAtNanoseconds >= toolTipDelayNanoseconds else { return }
        guard let text = area.resolvedToolTip(), !text.isEmpty else { return }
        toolTipShown = true
        let anchor = toolTipAnchor(for: area)
        showToolTip(text, at: anchor)
        onToolTipChange?(text, anchor)
    }

    /// Nanoseconds until the current hover's tooltip becomes eligible.
    ///
    /// Hosts fold this into their event-loop deadline so a stationary pointer
    /// can reveal a tooltip without requiring a free-running frame clock.
    public func nanosecondsUntilToolTip(atNanoseconds now: UInt64) -> UInt64? {
        guard !toolTipShown,
              let area = activeTrackingArea,
              let text = area.resolvedToolTip(),
              !text.isEmpty
        else { return nil }
        let elapsed = now >= hoverBeganAtNanoseconds
            ? now - hoverBeganAtNanoseconds
            : 0
        return elapsed >= toolTipDelayNanoseconds
            ? 0
            : toolTipDelayNanoseconds - elapsed
    }

    /// Whether the scene draws tooltips itself. A host that renders its own
    /// tooltip chrome turns this off and works from `onToolTipChange`.
    public var drawsToolTips = true

    private var toolTipPopover: Popover?

    private func showToolTip(_ text: String, at anchor: Rect) {
        guard drawsToolTips else { return }
        hideToolTip()

        let label = Label(text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Color(0.94, 0.95, 0.98, 1)
        label.frame = Rect(origin: .zero, size: label.intrinsicContentSize)

        // A tooltip is dismissed by movement and nothing else: it is not
        // focusable, it takes no clicks, and it must never sit between the
        // pointer and the thing it describes.
        let popover = Popover.withChrome(
            content: label, anchor: anchor, preferring: .below,
            dismissal: .anyClickPassively,
            padding: EdgeInsets(top: 5, left: 8, bottom: 5, right: 8),
            level: .criticalOverlay)
        popover.window.participatesInHitTesting = false
        // However it goes away — click, area change, or the host — the scene
        // must stop holding a dismissed popover.
        popover.onDismiss = { [weak self] in self?.toolTipPopover = nil }
        toolTipPopover = popover
        present(popover)
    }

    private func hideToolTip() {
        if let existing = toolTipPopover { dismiss(existing) }
        toolTipPopover = nil
    }

    /// The anchor a tooltip positions against: the tracked area in scene
    /// coordinates. Anchoring to the area rather than to the pointer keeps a
    /// tooltip still while the pointer moves inside the widget.
    private func toolTipAnchor(for area: TrackingArea) -> Rect {
        guard let owner = area.owner, let window = window(containing: owner) else {
            return .zero
        }
        let local = area.rect ?? owner.bounds
        let inWindow = owner.convert(local, to: nil)
        return window.sceneRect(fromWindow: inWindow)
    }

    private func window(containing view: View) -> Window? {
        var node: View? = view
        while let current = node {
            if let window = windows.first(where: { $0.root === current }) { return window }
            node = current.parentView
        }
        return nil
    }

    /// Rebase a scene-space location into `hit`'s view.
    ///
    /// Scene space is window space offset by the window's frame, and from there
    /// `View.convert` is the single definition of the coordinate system — which
    /// is why this no longer walks frame origins by hand: that walk ignored
    /// `boundsOrigin`, so a click inside a scrolled view landed at the wrong
    /// place.
    private func convert(_ point: Point, toViewIn hit: WindowHitTestResult) -> Point {
        let inWindow = hit.window.windowPoint(fromScene: point)
        return hit.view.convert(inWindow, from: nil)
    }

    public func hitTest(at point: Point) -> WindowHitTestResult? {
        for window in windowsForDisplay().reversed() where window.isVisible && window.participatesInHitTesting {
            let localPoint = window.windowPoint(fromScene: point)
            guard let root = window.root, let view = root.hitTest(localPoint) else {
                continue
            }
            return .init(window: window, view: view)
        }
        return nil
    }

    public func hitTestWindow(at point: Point) -> Window? {
        hitTest(at: point)?.window
    }

    private func windowsForDisplay() -> [Window] {
        windows.enumerated().sorted { lhs, rhs in
            let lhsLevel = lhs.element.level.rawValue
            let rhsLevel = rhs.element.level.rawValue
            if lhsLevel != rhsLevel {
                return lhsLevel < rhsLevel
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

}
