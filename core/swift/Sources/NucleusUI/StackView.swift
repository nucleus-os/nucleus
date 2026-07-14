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

    public var axis: Axis {
        didSet { setNeedsLayout() }
    }
    public var spacing: Double {
        didSet { setNeedsLayout() }
    }
    public var alignment: Alignment {
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

    public init(axis: Axis = .vertical, spacing: Double = 0, alignment: Alignment = .fill) throws(UIError) {
        self.axis = axis
        self.spacing = spacing
        self.alignment = alignment
        self.layoutMargins = .zero
        self.hidesHiddenArrangedSubviews = true
        self.arranged = []
        self.queuedRemovals = []
        self.activeRemoval = nil
        try super.init()
    }

    public var arrangedSubviews: [View] {
        arranged
    }

    public func addArrangedSubview(_ view: View) throws(UIError) {
        try addSubview(view)
        arranged.append(view)
        setNeedsLayout()
    }

    public func removeArrangedSubview(_ view: View) throws(UIError) {
        arranged.removeAll { $0 === view }
        try view.removeFromSuperview()
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
                    try removeArrangedSubview(activeRemoval.queued.view)
                    activeRemoval.queued.didRemove?()
                    activeRemoval.phase = .reflowing
                    activeRemoval.startedNs = nowNs
                    self.activeRemoval = activeRemoval
                    try animateInOwnContext(actionPolicy: activeRemoval.queued.reflow.actionPolicy) {
                        self.setNeedsLayout()
                        try self.layoutIfNeeded()
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

    open override func layout() throws(UIError) {
        let bounds = frame
        let contentX = bounds.origin.x + layoutMargins.left
        let contentY = bounds.origin.y + layoutMargins.top
        let contentWidth = max(0, bounds.size.width - layoutMargins.left - layoutMargins.right)
        let contentHeight = max(0, bounds.size.height - layoutMargins.top - layoutMargins.bottom)
        var cursor: Double = 0

        for view in arranged where !(hidesHiddenArrangedSubviews && view.isHidden) {
            let preferred = try preferredSize(for: view)
            let childFrame: Rect
            switch axis {
            case .vertical:
                let childWidth = crossAxisSize(preferred: preferred.width, available: contentWidth)
                childFrame = Rect(
                    x: contentX + crossAxisOffset(size: childWidth, available: contentWidth),
                    y: contentY + cursor,
                    width: childWidth,
                    height: preferred.height
                )
                cursor += preferred.height + spacing
            case .horizontal:
                let childHeight = crossAxisSize(preferred: preferred.height, available: contentHeight)
                childFrame = Rect(
                    x: contentX + cursor,
                    y: contentY + crossAxisOffset(size: childHeight, available: contentHeight),
                    width: preferred.width,
                    height: childHeight
                )
                cursor += preferred.width + spacing
            }
            if !isArrangedSubviewExiting(view) {
                view.frame = childFrame
            }
        }
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

    private func preferredSize(for view: View) throws(UIError) -> Size {
        let intrinsic = view.intrinsicContentSize
        let current = view.frame.size
        return Size(
            width: intrinsic.width > 0 ? intrinsic.width : current.width,
            height: intrinsic.height > 0 ? intrinsic.height : current.height
        )
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
