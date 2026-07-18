import NucleusLayers

public struct ArrangedSubviewRemovalTransition: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case slideTrailingFade
    }

    public var kind: Kind
    public var durationNs: UInt64
    public var actionPolicy: ActionPolicy

    public init(kind: Kind, duration: Double, actionPolicy: ActionPolicy = .default) {
        self.kind = kind
        self.durationNs = UInt64(max(0, duration) * 1_000_000_000)
        self.actionPolicy = actionPolicy
    }

    public static func slideTrailingFade(duration: Double = 0.24) -> ArrangedSubviewRemovalTransition {
        ArrangedSubviewRemovalTransition(kind: Kind.slideTrailingFade, duration: duration)
    }
}

public struct ArrangedSubviewReflowTransition: Sendable, Equatable {
    public var durationNs: UInt64
    public var actionPolicy: ActionPolicy

    public init(duration: Double, actionPolicy: ActionPolicy = .default) {
        self.durationNs = UInt64(max(0, duration) * 1_000_000_000)
        self.actionPolicy = actionPolicy
    }

    public static func animated(duration: Double = 0.22) -> ArrangedSubviewReflowTransition {
        ArrangedSubviewReflowTransition(duration: duration)
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
    }

    /// How main-axis space is apportioned. Mirrors `NSStackView.Distribution`.
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

    public var axis: Axis {
        didSet { setNeedsLayout() }
    }
    public var spacing: Double {
        didSet { setNeedsLayout() }
    }
    public var alignment: Alignment {
        didSet { setNeedsLayout() }
    }
    public var distribution: Distribution {
        didSet { setNeedsLayout() }
    }
    public var layoutMargins: EdgeInsets {
        didSet { setNeedsLayout() }
    }
    public var hidesHiddenArrangedSubviews: Bool {
        didSet { setNeedsLayout() }
    }
    private struct QueuedRemoval: ~Sendable {
        var view: View
        var transition: ArrangedSubviewRemovalTransition
        var reflow: ArrangedSubviewReflowTransition
        var didRemove: (() -> Void)?
        var completion: (() -> Void)?
    }

    private struct ActiveRemoval: ~Sendable {
        enum Phase {
            case exiting
            case reflowing
        }

        var queued: QueuedRemoval
        var phase: Phase
        var startedNs: UInt64
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
        self.axis = axis
        self.spacing = spacing
        self.alignment = alignment
        self.distribution = distribution
        self.layoutMargins = .zero
        self.hidesHiddenArrangedSubviews = true
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
        for existing in arranged where !views.contains(where: { $0 === existing }) {
            existing.removeFromSuperview()
        }
        for view in views where !arranged.contains(where: { $0 === view }) {
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
        nowNs: UInt64,
        didRemove: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) throws(UIError) -> Bool {
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
        try startNextArrangedSubviewRemovalIfNeeded(nowNs: nowNs)
        return true
    }

    public func advanceArrangedSubviewTransitions(nowNs: UInt64) throws(UIError) {
        if var activeRemoval {
            switch activeRemoval.phase {
            case .exiting:
                if nowNs >= activeRemoval.startedNs + activeRemoval.queued.transition.durationNs {
                    removeArrangedSubview(activeRemoval.queued.view)
                    activeRemoval.queued.didRemove?()
                    activeRemoval.phase = .reflowing
                    activeRemoval.startedNs = nowNs
                    self.activeRemoval = activeRemoval
                    try animateInOwnContext(actionPolicy: activeRemoval.queued.reflow.actionPolicy) {
                        self.setNeedsLayout()
                        self.layoutIfNeeded()
                    }
                }
            case .reflowing:
                if nowNs >= activeRemoval.startedNs + activeRemoval.queued.reflow.durationNs {
                    activeRemoval.queued.completion?()
                    self.activeRemoval = nil
                    try startNextArrangedSubviewRemovalIfNeeded(nowNs: nowNs)
                }
            }
        } else {
            try startNextArrangedSubviewRemovalIfNeeded(nowNs: nowNs)
        }
    }

    public var arrangedSubviewTransitionActive: Bool {
        activeRemoval != nil || !queuedRemovals.isEmpty
    }

    public var nextArrangedSubviewTransitionDeadlineNs: UInt64? {
        guard let activeRemoval else {
            return nil
        }
        switch activeRemoval.phase {
        case .exiting:
            return activeRemoval.startedNs + activeRemoval.queued.transition.durationNs
        case .reflowing:
            return activeRemoval.startedNs + activeRemoval.queued.reflow.durationNs
        }
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
            view.layoutBasis ?? mainAxisValue(measured[index])
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
            let used = mainSizes.reduce(0, +)
            if views.count > 1 {
                gap = max(spacing, (contentMain - used) / Double(views.count - 1))
            }
        }

        var cursor: Double = 0
        for (index, view) in views.enumerated() {
            let mainSize = mainSizes[index]
            let crossSize = crossAxisSize(
                preferred: crossAxisValue(measured[index]), available: contentCross)
            let crossOffset = crossAxisOffset(size: crossSize, available: contentCross)
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
        let used = sizes.reduce(0, +)
        let free = available - used
        guard abs(free) > 0.0001 else { return }

        if free > 0 {
            let totalGrow = views.reduce(0) { $0 + max(0, $1.growFactor) }
            guard totalGrow > 0 else { return }
            for index in sizes.indices {
                sizes[index] += free * max(0, views[index].growFactor) / totalGrow
            }
        } else {
            // Weighted by size as well as factor: a large child absorbs more of
            // the deficit than a small one at the same shrink factor.
            let weights = views.enumerated().map { index, view in
                max(0, view.shrinkFactor) * sizes[index]
            }
            let totalWeight = weights.reduce(0, +)
            guard totalWeight > 0 else { return }
            for index in sizes.indices {
                sizes[index] = max(0, sizes[index] + free * weights[index] / totalWeight)
            }
        }
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

    private func startNextArrangedSubviewRemovalIfNeeded(nowNs: UInt64) throws(UIError) {
        guard activeRemoval == nil, !queuedRemovals.isEmpty else {
            return
        }
        let queued = queuedRemovals.removeFirst()
        activeRemoval = .init(queued: queued, phase: .exiting, startedNs: nowNs)
        try animateInOwnContext(actionPolicy: queued.transition.actionPolicy) {
            try apply(queued.transition, to: queued.view)
        }
    }

    private func apply(_ transition: ArrangedSubviewRemovalTransition, to view: View) throws(UIError) {
        switch transition.kind {
        case .slideTrailingFade:
            view.frame = Rect(
                x: view.frame.origin.x + view.frame.size.width + 16,
                y: view.frame.origin.y,
                width: view.frame.size.width,
                height: view.frame.size.height
            )
            view.alphaValue = 0
        }
    }

    private func animateInOwnContext(
        actionPolicy: ActionPolicy,
        _ body: () throws -> Void
    ) throws(UIError) {
        try Transaction.run(in: backingLayer.context, actionPolicy: actionPolicy) {
            try body()
        }
    }

    private func crossAxisSize(preferred: Double, available: Double) -> Double {
        alignment == .fill ? available : preferred
    }

    private func crossAxisOffset(size: Double, available: Double) -> Double {
        switch alignment {
        case .leading, .fill:
            return 0
        case .center:
            return max(0, (available - size) / 2)
        case .trailing:
            return max(0, available - size)
        }
    }
}
