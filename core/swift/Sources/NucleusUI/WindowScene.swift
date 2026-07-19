import NucleusLayers
import Tracy

@MainActor
public struct WindowHitTestResult {
    public let window: Window
    public let view: View
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
    public private(set) var windows: [Window] = []
    public private(set) var keyWindow: Window?

    /// The view a press latched onto, if any. Drags and the release go here
    /// regardless of where the pointer currently is.
    private var pointerCapture: WindowHitTestResult?
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

    public init(
        windows: [Window] = []
    ) {
        self.publisher = WindowLayerPublisher(context: Application.currentContext)
        self.visualContext = Application.currentContext
        for window in windows {
            addWindow(window)
        }
    }

    package init(
        windows: [Window] = [],
        visualContext: Context
    ) {
        self.visualContext = visualContext
        self.publisher = WindowLayerPublisher(context: visualContext)
        for window in windows {
            addWindow(window)
        }
    }

    public func addWindow(_ window: Window) {
        guard !windows.contains(where: { $0 === window }) else {
            return
        }
        windows.append(window)
        window.windowScene = self
    }

    @discardableResult
    public func removeWindow(_ window: Window) -> Bool {
        let oldCount = windows.count
        windows.removeAll { $0 === window }
        if window.windowScene === self {
            window.windowScene = nil
        }
        if keyWindow === window {
            keyWindow = nil
            window.setKey(false)
        }
        return windows.count != oldCount
    }

    public func orderFront(_ window: Window) {
        addWindow(window)
        windows.removeAll { $0 === window }
        windows.append(window)
        window.setVisible(true)
    }

    public func orderOut(_ window: Window) {
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
        releasePointerCapture()
    }

    /// The scene's root layer, created and attached on first use. An embedder
    /// attaching its own content parents it here.
    package func ensureRootAttached() throws(UIError) -> Layer {
        try publisher.ensureRootAttached()
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
        if event.isKeyEvent {
            guard let keyWindow else { return .notHandled }
            return keyWindow.deliverKeyEvent(event)
        }

        if let capture = pointerCapture {
            let local = convert(event.location, toViewIn: capture)
            let delivered = capture.view.deliverEvent(event.relocated(to: local))
            if event.type == .pointerUp { releasePointerCapture() }
            return delivered
        }

        guard let hit = hitTest(at: event.location) else {
            // Nothing under the pointer: whatever was hovered no longer is.
            updateHover(nil, event: event)
            return .notHandled
        }
        let localEvent = event.relocated(to: convert(event.location, toViewIn: hit))

        // A press captures, so the release and any intervening drags reach the
        // same view even if the pointer has moved off it. Without this a
        // control could never distinguish "released on me" from "released
        // somewhere else", which is what makes drag-cancel possible.
        if event.type == .pointerDown {
            pointerCapture = hit
        }
        updateTrackedView(hit.view, event: localEvent)
        updateHover(hit, event: event)
        return hit.view.deliverEvent(localEvent)
    }

    /// Give up an active pointer capture without delivering anything.
    public func releasePointerCapture() {
        pointerCapture = nil
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
        let inWindow = Point(
            x: scenePoint.x - hit.window.frame.origin.x,
            y: scenePoint.y - hit.window.frame.origin.y)

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
        onToolTipChange?(text, toolTipAnchor(for: area))
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
        return Rect(
            x: inWindow.origin.x + window.frame.origin.x,
            y: inWindow.origin.y + window.frame.origin.y,
            width: inWindow.size.width,
            height: inWindow.size.height)
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
        let inWindow = Point(
            x: point.x - hit.window.frame.origin.x,
            y: point.y - hit.window.frame.origin.y)
        return hit.view.convert(inWindow, from: nil)
    }

    public func hitTest(at point: Point) -> WindowHitTestResult? {
        for window in windowsForDisplay().reversed() where window.isVisible && window.participatesInHitTesting {
            guard let root = window.root, let view = root.hitTest(point) else {
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
