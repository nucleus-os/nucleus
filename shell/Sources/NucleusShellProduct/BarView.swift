import NucleusUI

/// The bar: three sections of widgets, with chrome drawn behind them.
///
/// Sections are named along the main axis — start, center, end — rather than
/// left and right, because the same bar runs vertically down a screen edge and
/// "left" would then be a lie.
@MainActor
public final class BarView: View {
    public enum Section: Sendable, Equatable, CaseIterable {
        case start, center, end
    }

    /// Which way the bar runs. A vertical bar stacks its widgets and the
    /// sections run top, middle, bottom.
    public var axis: StackView.Axis = .horizontal {
        didSet {
            guard axis != oldValue else { return }
            for stack in sectionStacks.values { stack.axis = axis }
            setNeedsLayout()
        }
    }

    public var thickness: Double = 30 {
        didSet {
            guard thickness != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// Space between widgets within a section.
    public var widgetSpacing: Double = 6 {
        didSet {
            guard widgetSpacing != oldValue else { return }
            for stack in sectionStacks.values { stack.spacing = widgetSpacing }
            setNeedsLayout()
        }
    }

    /// Room between the bar's edge and the start and end sections.
    public var edgeMargin: Double = 10 {
        didSet { if edgeMargin != oldValue { setNeedsLayout() } }
    }

    /// Padding inside a capsule, around the widgets it covers.
    public var capsulePadding: Double = 6 {
        didSet { if capsulePadding != oldValue { updateChrome() } }
    }

    public var capsuleColor: ColorSpec = .role(.surfaceVariant) {
        didSet { if capsuleColor != oldValue { updateChrome() } }
    }

    public var hoverColor: ColorSpec = .role(.hover) {
        didSet { if hoverColor != oldValue { updateChrome() } }
    }

    /// Chrome sits *behind* the widgets and outside their layout.
    ///
    /// A hover highlight drawn by the widget would either take part in the
    /// layout — moving its neighbours when the pointer arrives — or be clipped
    /// at the section's edge. Neither is acceptable for a highlight that is
    /// meant to be a wash of colour under something, so the bar draws it in a
    /// layer of its own that no widget can affect.
    private let underlay = BarUnderlayView()
    private var sectionStacks: [Section: StackView] = [:]
    private var widgets: [Section: [BarWidget]] = [:]

    public override init() {
        super.init()
        addSubview(underlay)
        for section in Section.allCases {
            let stack = StackView(axis: .horizontal, spacing: widgetSpacing, alignment: .center)
            stack.shrinkFactor = 0
            sectionStacks[section] = stack
            widgets[section] = []
            addSubview(stack)
        }
    }

    // MARK: - Widgets

    public func widgets(in section: Section) -> [BarWidget] {
        widgets[section] ?? []
    }

    /// Replace a section's widgets.
    ///
    /// Whole-section replacement rather than insert and remove, because that is
    /// what a configuration reload produces: the widget list is authored as a
    /// list, and reconciling it item by item would be inventing an edit script
    /// nobody wrote.
    public func setWidgets(_ replacement: [BarWidget], in section: Section) {
        guard let stack = sectionStacks[section] else { return }
        for widget in widgets[section] ?? [] {
            widget.barNeedsChromeUpdate = nil
            widget.removeFromSuperview()
        }
        widgets[section] = replacement
        for widget in replacement {
            widget.barNeedsChromeUpdate = { [weak self] in self?.updateChrome() }
            stack.addArrangedSubview(widget)
        }
        setNeedsLayout()
        updateChrome()
    }

    /// Every widget, in section order.
    public var allWidgets: [BarWidget] {
        Section.allCases.flatMap { widgets[$0] ?? [] }
    }

    /// Ask every widget to re-read what it displays.
    public func refreshWidgets() {
        for widget in allWidgets { widget.refresh() }
    }

    /// Whether any widget wants a per-frame callback. The frame loop asks this
    /// rather than ticking unconditionally, so an idle bar stays idle.
    public var wantsFrameTick: Bool {
        allWidgets.contains { $0.wantsFrameTick }
    }

    /// Tick the widgets that asked for it, and nothing else.
    public func frameTick(deltaSeconds: Double) {
        for widget in allWidgets where widget.wantsFrameTick {
            widget.frameTick(deltaSeconds: deltaSeconds)
        }
    }

    // MARK: - Layout

    public override var intrinsicContentSize: Size {
        axis == .horizontal
            ? Size(width: 0, height: thickness)
            : Size(width: thickness, height: 0)
    }

    public override func layout() {
        super.layout()
        let size = bounds.size
        underlay.frame = Rect(origin: .zero, size: size)

        for section in Section.allCases {
            guard let stack = sectionStacks[section] else { continue }
            let fitting = stack.measure(LayoutConstraints.upTo(size))
            stack.arrange(in: sectionFrame(section, fitting: fitting, in: size))
        }
        updateChrome()
    }

    /// Where a section sits.
    ///
    /// The centre section is centred on the *bar*, not on the space left over
    /// between the other two. A clock that drifts when a tray icon appears is
    /// the thing every status bar gets wrong, and flexible spacers on either
    /// side produce exactly that — they only centre when the two ends happen to
    /// be the same size.
    private func sectionFrame(_ section: Section, fitting: Size, in size: Size) -> Rect {
        let horizontal = axis == .horizontal
        let available = horizontal ? size.width : size.height
        let length = horizontal ? fitting.width : fitting.height
        let breadth = horizontal ? size.height : size.width

        let position: Double
        switch section {
        case .start:
            position = edgeMargin
        case .center:
            position = (available - length) / 2
        case .end:
            position = available - length - edgeMargin
        }

        return horizontal
            ? Rect(x: position, y: 0, width: length, height: breadth)
            : Rect(x: 0, y: position, width: breadth, height: length)
    }

    // MARK: - Chrome

    /// Recompute the capsules and hover highlights drawn behind the widgets.
    func updateChrome() {
        var runs: [BarUnderlayView.Shape] = []
        let radius = axis == .horizontal
            ? bounds.size.height / 2
            : bounds.size.width / 2

        for section in Section.allCases {
            for run in capsuleRuns(in: section) {
                guard let box = unionFrame(of: run) else { continue }
                runs.append(BarUnderlayView.Shape(
                    rect: box.insetBy(-capsulePadding),
                    cornerRadius: radius,
                    color: resolve(capsuleColor)))
            }
        }

        // Hover sits above the capsules and below the widgets, so a hovered
        // widget inside a capsule reads as lit rather than outlined.
        var hovers: [BarUnderlayView.Shape] = []
        for widget in allWidgets where widget.isHovered {
            guard let box = unionFrame(of: [widget]) else { continue }
            hovers.append(BarUnderlayView.Shape(
                rect: box.insetBy(-capsulePadding / 2),
                cornerRadius: radius,
                color: resolve(hoverColor)))
        }

        underlay.shapes = runs + hovers
    }

    /// Consecutive capsule-showing widgets, grouped.
    ///
    /// Adjacency is the whole rule: a run is broken by a widget that declines a
    /// capsule, so `[a b] c [d]` is two capsules and a bare widget rather than
    /// one capsule with a hole in it.
    func capsuleRuns(in section: Section) -> [[BarWidget]] {
        var runs: [[BarWidget]] = []
        var current: [BarWidget] = []
        for widget in widgets[section] ?? [] {
            if widget.showsCapsule && !widget.isHidden {
                current.append(widget)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The rectangle covering a run, in bar coordinates.
    private func unionFrame(of run: [BarWidget]) -> Rect? {
        guard !run.isEmpty else { return nil }
        var result: Rect?
        for widget in run {
            let frame = convert(widget.bounds, from: widget)
            result = result.map { $0.union(frame) } ?? frame
        }
        return result
    }
}

/// Draws the bar's chrome: capsules behind runs of widgets, and hover
/// highlights. Owns no widgets and takes no input — it is a backdrop.
@MainActor
final class BarUnderlayView: View {
    struct Shape: Equatable {
        var rect: Rect
        var cornerRadius: Double
        var color: Color
    }

    var shapes: [Shape] = [] {
        didSet { if shapes != oldValue { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        isAccessibilityElement = false
    }

    /// The backdrop is never a target: a click belongs to the widget above it,
    /// and a hit here would swallow one.
    override func hitTest(_ point: Point) -> View? { nil }

    override func draw(in context: GraphicsContext) {
        for shape in shapes {
            context.fillColor = shape.color
            var path = Path()
            path.addRoundedRect(shape.rect, radius: shape.cornerRadius)
            context.fill(path)
        }
    }
}
