import NucleusLayers

public struct ArrangedSubviewRemovalTransition: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case slideTrailingFade
    }

    public var kind: Kind
    public var timing: AnimationTiming

    public init(kind: Kind, timing: AnimationTiming) {
        self.kind = kind
        self.timing = timing
    }

    public static func slideTrailingFade(duration: Double = 0.24) -> ArrangedSubviewRemovalTransition {
        ArrangedSubviewRemovalTransition(
            kind: .slideTrailingFade,
            timing: AnimationTiming(duration: duration)
        )
    }
}

public struct ArrangedSubviewReflowTransition: Sendable, Equatable {
    public var timing: AnimationTiming

    public init(timing: AnimationTiming) {
        self.timing = timing
    }

    public static func animated(duration: Double = 0.22) -> ArrangedSubviewReflowTransition {
        ArrangedSubviewReflowTransition(
            timing: AnimationTiming(duration: duration)
        )
    }
}

@MainActor
open class StackView: View, ~Sendable {
    public enum Axis: Sendable, Equatable {
        case horizontal
        case vertical
    }

    public enum Alignment: Sendable, Equatable {
        case leading
        case center
        case trailing
        case fill
        case firstBaseline
        case lastBaseline
    }

    /// How main-axis space is apportioned. Corresponds to `NSStackView.Distribution`.
    public enum Distribution: Sendable, Equatable {
        /// Measured sizes, then `growFactor`/`shrinkFactor` absorb the surplus or
        /// deficit. The default, and the only one that honors flex.
        case fill
        /// Every child gets the same main-axis size.
        case fillEqually
        /// Sizes scaled so their ratios hold and the axis is exactly filled.
        case fillProportionally
        /// Measured sizes kept; surplus goes into the gaps instead.
        case equalSpacing
    }

    private var storedAxis: Axis
    public var axis: Axis {
        get { storedAxis }
        set {
            guard newValue != storedAxis else { return }
            storedAxis = newValue
            setNeedsLayout()
        }
    }
    private var storedSpacing: Double
    public var spacing: Double {
        get { storedSpacing }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedSpacing else { return }
            storedSpacing = value
            setNeedsLayout()
        }
    }
    private var storedAlignment: Alignment
    public var alignment: Alignment {
        get { storedAlignment }
        set {
            guard newValue != storedAlignment else { return }
            storedAlignment = newValue
            setNeedsLayout()
        }
    }
    private var storedDistribution: Distribution
    public var distribution: Distribution {
        get { storedDistribution }
        set {
            guard newValue != storedDistribution else { return }
            storedDistribution = newValue
            setNeedsLayout()
        }
    }
    private var storedLayoutMargins: EdgeInsets
    public var layoutMargins: EdgeInsets {
        get { storedLayoutMargins }
        set {
            let value = Self.canonicalInsets(newValue)
            guard value != storedLayoutMargins else { return }
            storedLayoutMargins = value
            setNeedsLayout()
        }
    }
    private var storedHidesHiddenArrangedSubviews: Bool
    public var hidesHiddenArrangedSubviews: Bool {
        get { storedHidesHiddenArrangedSubviews }
        set {
            guard newValue != storedHidesHiddenArrangedSubviews else { return }
            storedHidesHiddenArrangedSubviews = newValue
            setNeedsLayout()
        }
    }
    private struct QueuedRemoval: ~Sendable {
        var view: View
        var transition: ArrangedSubviewRemovalTransition
        var reflow: ArrangedSubviewReflowTransition
        var didRemove: (() -> Void)?
        var completion: (() -> Void)?
    }

    private struct ActiveRemoval: ~Sendable {
        enum Phase: Equatable {
            case exiting
            case reflowing
        }

        var queued: QueuedRemoval
        var phase: Phase
        var handle: AnimationHandle?
    }

    private var arranged: [View]
    private var queuedRemovals: [QueuedRemoval]
    private var activeRemoval: ActiveRemoval?

    public init(
        axis: Axis = .vertical,
        spacing: Double = 0,
        alignment: Alignment = .fill,
        distribution: Distribution = .fill
    ) {
        self.storedAxis = axis
        self.storedSpacing = spacing.isFinite ? max(0, spacing) : 0
        self.storedAlignment = alignment
        self.storedDistribution = distribution
        self.storedLayoutMargins = .zero
        self.storedHidesHiddenArrangedSubviews = true
        self.arranged = []
        self.queuedRemovals = []
        self.activeRemoval = nil
        super.init()
    }

    public var arrangedSubviews: [View] {
        arranged
    }

    public func addArrangedSubview(_ view: View) {
        addSubview(view)
        arranged.append(view)
        setNeedsLayout()
    }

    /// Replace the arranged set, keeping views that appear in both. Order comes
    /// from `views`, so a reordered body reorders the stack without detaching
    /// and re-adding the views that merely moved.
    package func replaceArrangedSubviews(with views: [View]) {
        let incomingIDs = Set(views.map(ObjectIdentifier.init))
        let existingIDs = Set(arranged.map(ObjectIdentifier.init))
        for existing in arranged where !incomingIDs.contains(ObjectIdentifier(existing)) {
            existing.removeFromSuperview()
        }
        for view in views where !existingIDs.contains(ObjectIdentifier(view)) {
            addSubview(view)
        }
        arranged = views
        setNeedsLayout()
    }

    public func removeArrangedSubview(_ view: View) {
        arranged.removeAll { $0 === view }
        view.removeFromSuperview()
        setNeedsLayout()
    }

    @discardableResult
    public func removeArrangedSubview(
        _ view: View,
        transition: ArrangedSubviewRemovalTransition,
        reflow: ArrangedSubviewReflowTransition,
        didRemove: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) -> Bool {
        guard arranged.contains(where: { $0 === view }) else {
            return false
        }
        guard !isArrangedSubviewRemovalQueued(view) else {
            return false
        }
        queuedRemovals.append(.init(
            view: view,
            transition: transition,
            reflow: reflow,
            didRemove: didRemove,
            completion: completion
        ))
        startNextArrangedSubviewRemovalIfNeeded()
        return true
    }

    public var arrangedSubviewTransitionActive: Bool {
        activeRemoval != nil || !queuedRemovals.isEmpty
    }

    public func isArrangedSubviewExiting(_ view: View) -> Bool {
        guard let activeRemoval else {
            return false
        }
        return activeRemoval.phase == .exiting && activeRemoval.queued.view === view
    }

    public func isArrangedSubviewRemovalQueued(_ view: View) -> Bool {
        if let activeRemoval, activeRemoval.queued.view === view {
            return true
        }
        return queuedRemovals.contains { $0.view === view }
    }

    /// The stack's own size within `constraints`: children measured against the
    /// space this stack would offer them, summed along the axis and maxed across
    /// it. Makes a stack usable as a child of another stack.
    open override func measure(_ constraints: LayoutConstraints) -> Size {
        let inner = constraints.inset(by: layoutMargins).looseningMinima
        let visible = visibleArrangedSubviews
        var mainTotal: Double = 0
        var crossMax: Double = 0
        for view in visible {
            let size = view.measure(childMeasurementConstraints(inner))
            mainTotal += mainAxisValue(size)
            crossMax = max(crossMax, crossAxisValue(size))
        }
        if visible.count > 1 {
            mainTotal += spacing * Double(visible.count - 1)
        }
        let content = sizeFromAxes(main: mainTotal, cross: crossMax)
        return constraints.constrain(Size(
            width: content.width + layoutMargins.left + layoutMargins.right,
            height: content.height + layoutMargins.top + layoutMargins.bottom))
    }

    open override func layout() {
        // Content origin is in *this stack's own* coordinate space, so it starts
        // at the margins — not at `frame.origin`. A child frame is expressed
        // relative to its superview, which is exactly what `hitTest` and every
        // hand-written `layout()` already assume.
        let size = frame.size
        let contentX = layoutMargins.left
        let contentY = layoutMargins.top
        let contentWidth = max(0, size.width - layoutMargins.left - layoutMargins.right)
        let contentHeight = max(0, size.height - layoutMargins.top - layoutMargins.bottom)
        let contentMain = axis == .vertical ? contentHeight : contentWidth
        let contentCross = axis == .vertical ? contentWidth : contentHeight

        let views = visibleArrangedSubviews
        guard !views.isEmpty else { return }

        let measurementConstraints = childMeasurementConstraints(
            LayoutConstraints(maxWidth: contentWidth, maxHeight: contentHeight).looseningMinima)
        let measured = views.map { resolvedSize(for: $0, in: measurementConstraints) }
        let totalSpacing = spacing * Double(views.count - 1)
        var mainSizes = views.enumerated().map { index, view in
            clampedMainExtent(
                view.layoutBasis ?? mainAxisValue(measured[index]),
                for: view)
        }
        var gap = spacing

        switch distribution {
        case .fill:
            resolveFlexibleSpace(
                &mainSizes, views: views, available: contentMain - totalSpacing)
        case .fillEqually:
            let each = max(0, (contentMain - totalSpacing) / Double(views.count))
            mainSizes = mainSizes.map { _ in each }
        case .fillProportionally:
            let total = mainSizes.reduce(0, +)
            if total > 0 {
                let available = max(0, contentMain - totalSpacing)
                mainSizes = mainSizes.map { $0 / total * available }
            }
        case .equalSpacing:
            if mainSizes.reduce(0, +) > contentMain {
                resolveFlexibleSpace(
                    &mainSizes, views: views, available: contentMain)
            }
            let used = mainSizes.reduce(0, +)
            if views.count > 1 {
                // Keep the configured minimum whenever it fits. When it does
                // not, the gaps contract to the exact remaining space instead
                // of forcing the final child past the container edge.
                gap = max(0, (contentMain - used) / Double(views.count - 1))
            }
        }

        let baselineOffsets = crossAxisBaselineOffsets(
            views: views, measured: measured, mainSizes: mainSizes,
            available: contentCross)
        var cursor: Double = 0
        for (index, view) in views.enumerated() {
            let mainSize = mainSizes[index]
            let crossSize = crossAxisSize(
                preferred: crossAxisValue(measured[index]), available: contentCross)
            let crossOffset = baselineOffsets?[index]
                ?? crossAxisOffset(size: crossSize, available: contentCross)
            let childFrame: Rect
            switch axis {
            case .vertical:
                childFrame = Rect(
                    x: contentX + crossOffset, y: contentY + cursor,
                    width: crossSize, height: mainSize)
            case .horizontal:
                childFrame = Rect(
                    x: contentX + cursor, y: contentY + crossOffset,
                    width: mainSize, height: crossSize)
            }
            cursor += mainSize + gap
            // An exiting child is mid-transition and owns its own frame; the
            // reflow animation reclaims its slot once the transition completes.
            if !isArrangedSubviewExiting(view) {
                view.arrange(in: childFrame)
            }
        }
    }

    /// Grow into surplus space or shrink out of overflow, weighted by each
    /// child's factor. Children with a zero factor keep their measured size, so
    /// a stack of fixed items plus one `growFactor: 1` spacer behaves as expected.
    private func resolveFlexibleSpace(
        _ sizes: inout [Double], views: [View], available: Double
    ) {
        sizes = FlexibleLayoutResolver.resolve(
            sizes, views: views, available: available)
    }

    private func clampedMainExtent(_ extent: Double, for view: View) -> Double {
        FlexibleLayoutResolver.clamp(extent, for: view)
    }

    private var visibleArrangedSubviews: [View] {
        arranged.filter { !(hidesHiddenArrangedSubviews && $0.isHidden) }
    }

    /// Children are measured with the cross axis bounded (so text wraps to the
    /// column) and the main axis free (so they report what they actually want
    /// before flexible space is resolved).
    private func childMeasurementConstraints(
        _ content: LayoutConstraints
    ) -> LayoutConstraints {
        switch axis {
        case .vertical:
            LayoutConstraints(maxWidth: content.maxWidth, maxHeight: .infinity)
        case .horizontal:
            LayoutConstraints(maxWidth: .infinity, maxHeight: content.maxHeight)
        }
    }

    /// A view that measures to zero on an axis has nothing to say about it, so
    /// it keeps whatever frame it was given — the escape hatch for children
    /// positioned by hand.
    private func resolvedSize(for view: View, in constraints: LayoutConstraints) -> Size {
        let measured = view.measure(constraints)
        let current = view.frame.size
        return Size(
            width: measured.width > 0 ? measured.width : current.width,
            height: measured.height > 0 ? measured.height : current.height)
    }

    private func mainAxisValue(_ size: Size) -> Double {
        axis == .vertical ? size.height : size.width
    }

    private func crossAxisValue(_ size: Size) -> Double {
        axis == .vertical ? size.width : size.height
    }

    private func sizeFromAxes(main: Double, cross: Double) -> Size {
        axis == .vertical
            ? Size(width: cross, height: main)
            : Size(width: main, height: cross)
    }

    private func startNextArrangedSubviewRemovalIfNeeded() {
        guard activeRemoval == nil, !queuedRemovals.isEmpty else {
            return
        }
        let queued = queuedRemovals.removeFirst()
        activeRemoval = .init(
            queued: queued,
            phase: .exiting,
            handle: nil
        )

        let initialFrame = queued.view.frame
        let initialOpacity = queued.view.alphaValue
        let key = AnimationPropertyKey(
            rawValue: "stack-exit-\(queued.view.id.rawValue)"
        )
        let handle = uiContext.animateValue(
            owner: self,
            property: key,
            from: 0,
            to: 1,
            options: ValueAnimationOptions(timing: queued.transition.timing)
        ) { [weak self, weak view = queued.view] progress in
            guard let self, let view else { return }
            switch queued.transition.kind {
            case .slideTrailingFade:
                view.frame = Rect(
                    x: initialFrame.origin.x +
                        (initialFrame.size.width + 16) * progress,
                    y: initialFrame.origin.y,
                    width: initialFrame.size.width,
                    height: initialFrame.size.height
                )
                view.alphaValue = initialOpacity * (1 - progress)
            }
            self.setNeedsDisplay()
        } completion: { [weak self] outcome in
            self?.exitAnimationDidFinish(outcome)
        }
        if activeRemoval?.phase == .exiting {
            activeRemoval?.handle = handle
        }
    }

    private func exitAnimationDidFinish(_ outcome: AnimationOutcome) {
        guard let active = activeRemoval, active.phase == .exiting else {
            return
        }
        guard outcome == .completed || outcome == .skippedReducedMotion else {
            activeRemoval = nil
            startNextArrangedSubviewRemovalIfNeeded()
            return
        }

        let oldFrames = Dictionary(
            uniqueKeysWithValues: arranged
                .filter { $0 !== active.queued.view }
                .map { ($0.id, $0.frame) }
        )
        removeArrangedSubview(active.queued.view)
        active.queued.didRemove?()
        setNeedsLayout()
        layoutIfNeeded()
        let finalFrames = Dictionary(
            uniqueKeysWithValues: arranged.map { ($0.id, $0.frame) }
        )
        for view in arranged {
            if let old = oldFrames[view.id] {
                view.frame = old
            }
        }

        activeRemoval = .init(
            queued: active.queued,
            phase: .reflowing,
            handle: nil
        )
        let key = AnimationPropertyKey(
            rawValue: "stack-reflow-\(active.queued.view.id.rawValue)"
        )
        let handle = uiContext.animateValue(
            owner: self,
            property: key,
            from: 0,
            to: 1,
            options: ValueAnimationOptions(timing: active.queued.reflow.timing)
        ) { [weak self] progress in
            guard let self else { return }
            for view in arranged {
                guard let final = finalFrames[view.id] else { continue }
                let initial = oldFrames[view.id] ?? final
                view.frame = Rect.interpolate(
                    from: initial,
                    to: final,
                    progress: progress
                )
            }
        } completion: { [weak self] outcome in
            self?.reflowAnimationDidFinish(outcome)
        }
        if activeRemoval?.phase == .reflowing {
            activeRemoval?.handle = handle
        }
    }

    private func reflowAnimationDidFinish(_ outcome: AnimationOutcome) {
        guard let active = activeRemoval, active.phase == .reflowing else {
            return
        }
        if outcome == .completed || outcome == .skippedReducedMotion {
            active.queued.completion?()
        }
        activeRemoval = nil
        startNextArrangedSubviewRemovalIfNeeded()
    }

    private func crossAxisSize(preferred: Double, available: Double) -> Double {
        alignment == .fill ? available : preferred
    }

    private func crossAxisOffset(size: Double, available: Double) -> Double {
        switch alignment {
        case .leading, .fill, .firstBaseline, .lastBaseline:
            return 0
        case .center:
            return max(0, (available - size) / 2)
        case .trailing:
            return max(0, available - size)
        }
    }

    private func crossAxisBaselineOffsets(
        views: [View],
        measured: [Size],
        mainSizes: [Double],
        available: Double
    ) -> [Double]? {
        guard axis == .horizontal,
              alignment == .firstBaseline || alignment == .lastBaseline
        else { return nil }

        var positions: [Double] = []
        positions.reserveCapacity(views.count)
        for index in views.indices {
            let cross = crossAxisSize(
                preferred: crossAxisValue(measured[index]), available: available)
            let size = Size(width: mainSizes[index], height: cross)
            let metrics = (views[index] as? any LayoutBaselineProviding)?
                .layoutBaselines(for: size)
            switch alignment {
            case .firstBaseline:
                positions.append(metrics?.firstFromTop ?? cross)
            case .lastBaseline:
                positions.append(cross - (metrics?.lastFromBottom ?? 0))
            default:
                preconditionFailure("baseline offsets requested for non-baseline alignment")
            }
        }
        let reference = positions.max() ?? 0
        return positions.map { max(0, reference - $0) }
    }

    private static func canonicalInsets(_ insets: EdgeInsets) -> EdgeInsets {
        func value(_ input: Double) -> Double {
            input.isFinite ? max(0, input) : 0
        }
        return EdgeInsets(
            top: value(insets.top), left: value(insets.left),
            bottom: value(insets.bottom), right: value(insets.right))
    }
}

private extension Rect {
    static func interpolate(
        from: Rect,
        to: Rect,
        progress: Double
    ) -> Rect {
        Rect(
            x: from.origin.x + (to.origin.x - from.origin.x) * progress,
            y: from.origin.y + (to.origin.y - from.origin.y) * progress,
            width: from.size.width +
                (to.size.width - from.size.width) * progress,
            height: from.size.height +
                (to.size.height - from.size.height) * progress
        )
    }
}
