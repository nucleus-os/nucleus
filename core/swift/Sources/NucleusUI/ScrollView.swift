internal import NucleusLayers

/// Which scroll indicators a scroll view shows.
public struct ScrollIndicators: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let vertical = ScrollIndicators(rawValue: 1 << 0)
    public static let horizontal = ScrollIndicators(rawValue: 1 << 1)
    public static let both: ScrollIndicators = [.vertical, .horizontal]
}

/// The externally observable phase of one scroll interaction.
public enum ScrollInteractionPhase: Sendable, Equatable {
    case idle
    case dragging
    case decelerating
}

/// The clipping container a scroll view scrolls.
///
/// `NSClipView`'s role: it clips, and its `bounds.origin` *is* the scroll
/// position. Scrolling is one retained property mutation on this view; the
/// document inside neither moves nor redraws.
@MainActor
public final class ClipView: View {
    public override init() {
        super.init()
        clipsToBounds = true
    }
}

/// A scrolling container: a clip view, a document view, and retained indicators.
///
/// Virtualization belongs to containers that understand their item geometry,
/// such as `ListView` and `VirtualGridView`, rather than this arbitrary document
/// viewport.
@MainActor
open class ScrollView: View {
    public let clipView = ClipView()
    public let verticalScrollIndicator = ScrollIndicator(axis: .vertical)
    public let horizontalScrollIndicator = ScrollIndicator(axis: .horizontal)

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
        didSet {
            guard indicators != oldValue else { return }
            updateIndicatorGeometry()
            updateIndicatorVisibility()
        }
    }

    /// Axes on which content may move. Indicators are presentation policy;
    /// this value is the independent interaction and programmatic-scrolling
    /// policy.
    public var scrollableAxes: ScrollIndicators = .both {
        didSet {
            guard scrollableAxes != oldValue else { return }
            clampScrollPosition()
        }
    }

    public var indicatorVisibilityPolicy: ScrollIndicatorVisibilityPolicy = .automatic {
        didSet {
            guard indicatorVisibilityPolicy != oldValue else { return }
            updateIndicatorVisibility()
        }
    }

    /// How far one wheel notch scrolls. Continuous devices report their own
    /// deltas and bypass this.
    public var lineScrollDistance: Double = 40 {
        didSet {
            if !lineScrollDistance.isFinite || lineScrollDistance < 0 {
                lineScrollDistance = 0
            }
        }
    }

    /// Called after the scroll position changes, whatever moved it.
    public var onScroll: ((Point) -> Void)?
    package var onInternalScroll: ((Point) -> Void)?

    public private(set) var interactionPhase: ScrollInteractionPhase = .idle
    /// Points per second in content-offset coordinates.
    public private(set) var scrollVelocity: Point = .zero

    private static let indicatorThickness: Double = 4
    private static let indicatorHitThickness: Double = 12
    private static let indicatorInset: Double = 2
    private static let indicatorMinimumLength: Double = 24
    private static let kineticVelocityThreshold: Double = 30
    private static let kineticDeceleration: Double = 2_500

    private var dragLocation: Point?
    private var dragTimestampNanoseconds: UInt64?
    private var continuousTimestampNanoseconds: UInt64?
    private var kineticHandle: AnimationHandle?
    private var kineticGeneration: UInt64 = 0
    private var indicatorFadeGeneration: UInt64 = 0

    public override init() {
        super.init()
        clipsToBounds = true
        addSubview(clipView)
        addSubview(verticalScrollIndicator)
        addSubview(horizontalScrollIndicator)

        verticalScrollIndicator.onBeginInteraction = { [weak self] in
            self?.beginIndicatorInteraction()
        }
        horizontalScrollIndicator.onBeginInteraction = { [weak self] in
            self?.beginIndicatorInteraction()
        }
        verticalScrollIndicator.onEndInteraction = { [weak self] in
            self?.endDirectInteraction()
        }
        horizontalScrollIndicator.onEndInteraction = { [weak self] in
            self?.endDirectInteraction()
        }
        verticalScrollIndicator.onDragProgress = { [weak self] progress in
            guard let self else { return }
            self.contentOffset.y = self.maximumOffset.y * progress
        }
        horizontalScrollIndicator.onDragProgress = { [weak self] progress in
            guard let self else { return }
            self.contentOffset.x = self.maximumOffset.x * progress
        }
        verticalScrollIndicator.onPage = { [weak self] direction in
            self?.page(axis: .vertical, direction: direction)
        }
        horizontalScrollIndicator.onPage = { [weak self] direction in
            self?.page(axis: .horizontal, direction: direction)
        }

        updateIndicatorVisibility()
    }

    isolated deinit {
        kineticHandle?.cancel()
        uiContext.cancelAnimations(owner: verticalScrollIndicator)
        uiContext.cancelAnimations(owner: horizontalScrollIndicator)
    }

    // MARK: - Scroll position

    /// The scroll position is the clip view's bounds origin.
    public var contentOffset: Point {
        get { clipView.boundsOrigin }
        set {
            let clamped = clampedOffset(newValue)
            guard clamped != clipView.boundsOrigin else { return }
            clipView.boundsOrigin = clamped
            updateIndicatorGeometry()
            notifyScroll(clamped)
        }
    }

    public var contentSize: Size {
        documentView?.frame.size ?? .zero
    }

    public var maximumOffset: Point {
        let visible = clipView.frame.size
        let content = contentSize
        return Point(
            x: max(0, content.width - visible.width),
            y: max(0, content.height - visible.height))
    }

    private func clampedOffset(_ offset: Point) -> Point {
        let maximum = maximumOffset
        let x = offset.x.isFinite ? offset.x : 0
        let y = offset.y.isFinite ? offset.y : 0
        return Point(
            x: scrollableAxes.contains(.horizontal)
                ? min(max(0, x), maximum.x)
                : 0,
            y: scrollableAxes.contains(.vertical)
                ? min(max(0, y), maximum.y)
                : 0)
    }

    public func clampScrollPosition() {
        let clamped = clampedOffset(clipView.boundsOrigin)
        if clamped != clipView.boundsOrigin {
            clipView.boundsOrigin = clamped
            notifyScroll(clamped)
        }
        updateIndicatorGeometry()
    }

    private func notifyScroll(_ offset: Point) {
        onInternalScroll?(offset)
        onScroll?(offset)
    }

    /// Scroll the minimum distance needed to reveal a document-space rectangle.
    @discardableResult
    public func scrollToVisible(_ rect: Rect) -> Bool {
        let visible = Rect(origin: contentOffset, size: clipView.frame.size)
        var offset = contentOffset

        if rect.origin.x < visible.origin.x {
            offset.x = rect.origin.x
        } else if rect.origin.x + rect.size.width
            > visible.origin.x + visible.size.width
        {
            offset.x = rect.origin.x + rect.size.width - visible.size.width
        }

        if rect.origin.y < visible.origin.y {
            offset.y = rect.origin.y
        } else if rect.origin.y + rect.size.height
            > visible.origin.y + visible.size.height
        {
            offset.y = rect.origin.y + rect.size.height - visible.size.height
        }

        let before = contentOffset
        contentOffset = offset
        return contentOffset != before
    }

    // MARK: - Layout

    open override func layout() {
        clipView.frame = Rect(origin: .zero, size: bounds.size)

        let hit = ScrollView.indicatorHitThickness
        verticalScrollIndicator.frame = Rect(
            x: max(0, bounds.size.width - hit),
            y: 0,
            width: min(hit, bounds.size.width),
            height: bounds.size.height)
        horizontalScrollIndicator.frame = Rect(
            x: 0,
            y: max(0, bounds.size.height - hit),
            width: bounds.size.width,
            height: min(hit, bounds.size.height))

        clampScrollPosition()
    }

    // MARK: - Events

    open override func handleEvent(_ event: Event) -> EventHandling {
        switch event.type {
        case .scrollWheel:
            return handleScrollWheel(event)
        case .pointerDown, .touchDown:
            beginDrag(at: event.location, timestampNanoseconds: event.timestampNanoseconds)
            return .handled
        case .pointerDragged, .touchMoved:
            return continueDrag(
                to: event.location,
                timestampNanoseconds: event.timestampNanoseconds)
        case .pointerUp, .touchUp:
            guard dragLocation != nil else { return .notHandled }
            dragLocation = nil
            dragTimestampNanoseconds = nil
            startKineticScrollingIfNeeded()
            return .handled
        case .touchCancelled:
            guard dragLocation != nil else { return .notHandled }
            dragLocation = nil
            dragTimestampNanoseconds = nil
            cancelKineticScrolling()
            finishInteraction()
            return .handled
        default:
            return .notHandled
        }
    }

    private func handleScrollWheel(_ event: Event) -> EventHandling {
        if event.scrollPhase == .ended {
            let started = startKineticScrollingIfNeeded()
            continuousTimestampNanoseconds = nil
            return started ? .handled : .notHandled
        }

        cancelKineticScrolling()
        interactionPhase = .dragging
        showIndicators()

        let distance = event.scrollDistance(lineHeight: lineScrollDistance)
        let before = contentOffset
        contentOffset = Point(
            x: before.x + distance.x,
            y: before.y + distance.y)
        let actualDelta = Point(
            x: contentOffset.x - before.x,
            y: contentOffset.y - before.y)

        if event.hasPreciseScrollingDeltas {
            updateContinuousVelocity(
                actualDelta,
                timestampNanoseconds: event.timestampNanoseconds)
        } else {
            scrollVelocity = .zero
            continuousTimestampNanoseconds = nil
            finishInteraction()
        }

        // At a bound the event remains available to an ancestor scroll view.
        return actualDelta == .zero ? .notHandled : .handled
    }

    private func beginDrag(at location: Point, timestampNanoseconds: UInt64) {
        cancelKineticScrolling()
        interactionPhase = .dragging
        scrollVelocity = .zero
        dragLocation = location
        dragTimestampNanoseconds = timestampNanoseconds
        showIndicators()
    }

    private func continueDrag(
        to location: Point,
        timestampNanoseconds: UInt64
    ) -> EventHandling {
        guard let previous = dragLocation else { return .notHandled }
        let before = contentOffset
        contentOffset = Point(
            x: before.x - (location.x - previous.x),
            y: before.y - (location.y - previous.y))
        dragLocation = location
        let actualDelta = Point(
            x: contentOffset.x - before.x,
            y: contentOffset.y - before.y)
        updateVelocity(
            actualDelta,
            from: dragTimestampNanoseconds,
            to: timestampNanoseconds)
        dragTimestampNanoseconds = timestampNanoseconds
        return actualDelta == .zero ? .notHandled : .handled
    }

    private func updateContinuousVelocity(
        _ delta: Point,
        timestampNanoseconds: UInt64
    ) {
        updateVelocity(
            delta,
            from: continuousTimestampNanoseconds,
            to: timestampNanoseconds)
        continuousTimestampNanoseconds = timestampNanoseconds
    }

    private func updateVelocity(
        _ delta: Point,
        from previousTimestamp: UInt64?,
        to timestamp: UInt64
    ) {
        guard let previousTimestamp, timestamp > previousTimestamp else { return }
        let seconds = Double(timestamp - previousTimestamp) / 1_000_000_000
        guard seconds > 0, seconds.isFinite else { return }
        let instantaneous = Point(
            x: delta.x / seconds,
            y: delta.y / seconds)
        guard instantaneous.x.isFinite, instantaneous.y.isFinite else { return }
        // A stable low-pass sample avoids one noisy packet deciding the fling.
        scrollVelocity = Point(
            x: scrollVelocity.x * 0.25 + instantaneous.x * 0.75,
            y: scrollVelocity.y * 0.25 + instantaneous.y * 0.75)
    }

    @discardableResult
    private func startKineticScrollingIfNeeded() -> Bool {
        dragLocation = nil
        dragTimestampNanoseconds = nil

        let speed = (scrollVelocity.x * scrollVelocity.x
            + scrollVelocity.y * scrollVelocity.y).squareRoot()
        guard speed >= ScrollView.kineticVelocityThreshold,
              !uiContext.environment.reducesMotion
        else {
            scrollVelocity = .zero
            finishInteraction()
            return false
        }

        let duration = min(
            1,
            max(0.15, speed / ScrollView.kineticDeceleration))
        let start = contentOffset
        let target = clampedOffset(Point(
            x: start.x + scrollVelocity.x * duration * 0.5,
            y: start.y + scrollVelocity.y * duration * 0.5))
        guard target != start else {
            scrollVelocity = .zero
            finishInteraction()
            return false
        }

        cancelKineticScrolling()
        interactionPhase = .decelerating
        showIndicators()
        kineticGeneration &+= 1
        let generation = kineticGeneration
        kineticHandle = uiContext.animateValue(
            owner: self,
            property: AnimationPropertyKey(rawValue: "scroll.kinetic"),
            from: 0,
            to: 1,
            options: ValueAnimationOptions(
                timing: AnimationTiming(
                    duration: duration,
                    curve: .bezier(.easeOut))),
            update: { [weak self] progress in
                guard let self, self.kineticGeneration == generation else { return }
                self.contentOffset = Point(
                    x: start.x + (target.x - start.x) * progress,
                    y: start.y + (target.y - start.y) * progress)
            },
            completion: { [weak self] _ in
                guard let self, self.kineticGeneration == generation else { return }
                self.kineticHandle = nil
                self.scrollVelocity = .zero
                self.finishInteraction()
            })
        return true
    }

    private func cancelKineticScrolling() {
        guard kineticHandle != nil else { return }
        kineticGeneration &+= 1
        kineticHandle?.cancel()
        kineticHandle = nil
        scrollVelocity = .zero
    }

    // MARK: - Indicators

    /// The vertical thumb in this scroll view's coordinates.
    public func verticalIndicatorRect() -> Rect? {
        indicatorRect(axis: .vertical)
    }

    /// The horizontal thumb in this scroll view's coordinates.
    public func horizontalIndicatorRect() -> Rect? {
        indicatorRect(axis: .horizontal)
    }

    private func indicatorRect(axis: ScrollAxis) -> Rect? {
        let enabled = axis == .vertical
            ? indicators.contains(.vertical)
            : indicators.contains(.horizontal)
        guard enabled else { return nil }

        let travel = axis == .vertical ? maximumOffset.y : maximumOffset.x
        guard travel > 0 else { return nil }
        let extent = axis == .vertical ? bounds.size.height : bounds.size.width
        let track = max(0, extent - ScrollView.indicatorInset * 2)
        guard track > 0 else { return nil }
        let visible = axis == .vertical
            ? clipView.frame.size.height
            : clipView.frame.size.width
        let proportion = visible / max(visible + travel, 1)
        let length = min(
            track,
            max(ScrollView.indicatorMinimumLength, track * proportion))
        let offset = axis == .vertical ? contentOffset.y : contentOffset.x
        let progress = min(max(0, offset / travel), 1)
        let position = ScrollView.indicatorInset + (track - length) * progress

        if axis == .vertical {
            return Rect(
                x: max(0, bounds.size.width
                    - ScrollView.indicatorThickness
                    - ScrollView.indicatorInset),
                y: position,
                width: ScrollView.indicatorThickness,
                height: length)
        }
        return Rect(
            x: position,
            y: max(0, bounds.size.height
                - ScrollView.indicatorThickness
                - ScrollView.indicatorInset),
            width: length,
            height: ScrollView.indicatorThickness)
    }

    private func updateIndicatorGeometry() {
        if let rect = verticalIndicatorRect() {
            verticalScrollIndicator.setThumbRect(
                Rect(
                    x: rect.origin.x - verticalScrollIndicator.frame.origin.x,
                    y: rect.origin.y - verticalScrollIndicator.frame.origin.y,
                    width: rect.size.width,
                    height: rect.size.height))
        } else {
            verticalScrollIndicator.setThumbRect(.zero)
        }
        if let rect = horizontalIndicatorRect() {
            horizontalScrollIndicator.setThumbRect(
                Rect(
                    x: rect.origin.x - horizontalScrollIndicator.frame.origin.x,
                    y: rect.origin.y - horizontalScrollIndicator.frame.origin.y,
                    width: rect.size.width,
                    height: rect.size.height))
        } else {
            horizontalScrollIndicator.setThumbRect(.zero)
        }
        updateIndicatorVisibility()
    }

    private func indicatorIsAvailable(_ axis: ScrollAxis) -> Bool {
        switch axis {
        case .vertical:
            indicators.contains(.vertical) && maximumOffset.y > 0
        case .horizontal:
            indicators.contains(.horizontal) && maximumOffset.x > 0
        }
    }

    private func updateIndicatorVisibility() {
        let visibleByPolicy: Bool
        switch indicatorVisibilityPolicy {
        case .always:
            visibleByPolicy = true
        case .automatic, .whileScrolling:
            visibleByPolicy = interactionPhase != .idle
        case .never:
            visibleByPolicy = false
        }
        setIndicator(
            verticalScrollIndicator,
            available: indicatorIsAvailable(.vertical),
            visible: visibleByPolicy)
        setIndicator(
            horizontalScrollIndicator,
            available: indicatorIsAvailable(.horizontal),
            visible: visibleByPolicy)
    }

    private func setIndicator(
        _ indicator: ScrollIndicator,
        available: Bool,
        visible: Bool
    ) {
        if available && visible {
            indicator.isHidden = false
            indicator.alphaValue = 1
        } else {
            indicator.alphaValue = 0
            indicator.isHidden = true
        }
    }

    private func showIndicators() {
        indicatorFadeGeneration &+= 1
        updateIndicatorVisibility()
    }

    private func finishInteraction() {
        interactionPhase = .idle
        switch indicatorVisibilityPolicy {
        case .automatic:
            fadeIndicators()
        case .always, .whileScrolling, .never:
            updateIndicatorVisibility()
        }
    }

    private func fadeIndicators() {
        indicatorFadeGeneration &+= 1
        let generation = indicatorFadeGeneration
        for indicator in [verticalScrollIndicator, horizontalScrollIndicator]
        where !indicator.isHidden {
            uiContext.animateValue(
                owner: indicator,
                property: AnimationPropertyKey(rawValue: "scroll.indicator.opacity"),
                from: indicator.alphaValue,
                to: 0,
                options: ValueAnimationOptions(
                    timing: AnimationTiming(
                        duration: 0.25,
                        curve: .bezier(.easeOut))),
                update: { [weak self, weak indicator] alpha in
                    guard let self,
                          self.indicatorFadeGeneration == generation
                    else { return }
                    indicator?.alphaValue = alpha
                },
                completion: { [weak self, weak indicator] outcome in
                    guard let self,
                          self.indicatorFadeGeneration == generation,
                          outcome == .completed
                    else { return }
                    indicator?.isHidden = true
                })
        }
    }

    private func beginIndicatorInteraction() {
        cancelKineticScrolling()
        interactionPhase = .dragging
        scrollVelocity = .zero
        showIndicators()
    }

    private func endDirectInteraction() {
        scrollVelocity = .zero
        finishInteraction()
    }

    private func page(axis: ScrollAxis, direction: Int) {
        beginIndicatorInteraction()
        let delta: Double
        switch axis {
        case .vertical:
            delta = clipView.frame.size.height * 0.9 * Double(direction)
            contentOffset.y += delta
        case .horizontal:
            delta = clipView.frame.size.width * 0.9 * Double(direction)
            contentOffset.x += delta
        }
        endDirectInteraction()
    }
}
