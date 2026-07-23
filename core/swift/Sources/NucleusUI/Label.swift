internal import NucleusLayers

@MainActor
public final class Label: View, LayoutBaselineProviding, ~Sendable {
    public enum Alignment: Sendable, Equatable {
        case leading
        case center
        case trailing
    }

    public var text: String {
        didSet {
            if accessibilityLabel == oldValue {
                accessibilityLabel = text
            }
            invalidateLayoutCache()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
    public var alignment: Alignment {
        didSet {
            invalidateLayoutCache()
            setNeedsDisplay()
        }
    }
    public var fontSize: Float {
        get { font.pointSize }
        set { font = .systemFont(ofSize: newValue) }
    }
    public var font: Font {
        didSet {
            invalidateLayoutCache()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
    public var lineBreakMode: LineBreakMode {
        didSet {
            invalidateLayoutCache()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
    public var numberOfLines: Int {
        didSet {
            numberOfLines = max(1, numberOfLines)
            invalidateLayoutCache()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
    public var textColor: Color {
        didSet {
            // The cached layout carries the run color, so a color change must rebuild
            // it (metrics are unaffected, but drawing would otherwise re-color
            // and drop the paragraph storage).
            if textColor != oldValue { invalidateLayoutCache() }
            setNeedsDisplay()
        }
    }

    public init(_ text: String = "") {
        self.text = text
        self.alignment = .leading
        self.font = .systemFont(ofSize: 14)
        self.lineBreakMode = .byClipping
        self.numberOfLines = 1
        self.textColor = Color(1, 1, 1, 1)
        super.init()
        isAccessibilityElement = true
        accessibilityRole = .staticText
        accessibilityLabel = text
    }

    public override var intrinsicContentSize: Size {
        return textLayout(containerWidth: nil).intrinsicSize
    }

    public override var environmentDependencies: UIEnvironmentChanges {
        super.environmentDependencies.union(.textScale)
    }

    public override func environmentDidChange(
        _ changes: UIEnvironmentChanges
    ) {
        if changes.contains(.textScale) {
            invalidateLayoutCache()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
        super.environmentDidChange(changes)
    }

    /// The reason two-phase layout exists. A label's height is a function of the
    /// width it is given, so it measures its text against the proposed width
    /// rather than reporting the single-line intrinsic size and overflowing.
    public override func measure(_ constraints: LayoutConstraints) -> Size {
        let layout = textLayout(containerWidth: constraints.proposedWidth)
        return constraints.constrain(layout.intrinsicSize)
    }

    public var firstBaselineOffsetFromTop: Double {
        textLayout(containerWidth: Double(frame.size.width)).firstBaselineOffsetFromTop
    }

    public var lastBaselineOffsetFromBottom: Double {
        textLayout(containerWidth: Double(frame.size.width)).lastBaselineOffsetFromBottom
    }

    public func layoutBaselines(for size: Size) -> LayoutBaselineMetrics {
        let layout = textLayout(containerWidth: size.width)
        return LayoutBaselineMetrics(
            firstFromTop: layout.firstBaselineOffsetFromTop,
            lastFromBottom: layout.lastBaselineOffsetFromBottom)
    }

    public func placeBaseline(at baseline: Double, x: Double, width: Double) {
        let layout = textLayout(containerWidth: width)
        frame = Rect(
            x: x,
            y: baseline - layout.firstBaselineOffsetFromTop,
            width: width,
            height: layout.usedRect.size.height
        )
    }

    public func centerVertically(in rect: Rect) {
        let layout = textLayout(containerWidth: rect.size.width)
        frame = Rect(
            x: rect.origin.x,
            y: rect.origin.y + (rect.size.height - layout.usedRect.size.height) * 0.5,
            width: rect.size.width,
            height: layout.usedRect.size.height
        )
    }

    public override func draw(in context: GraphicsContext) {
        let layout = textLayout(containerWidth: Double(frame.size.width))
        guard !layout.isEmpty else { return }
        context.fillColor = textColor
        context.draw(layout, in: Rect(
            x: 0, y: 0,
            width: layout.usedRect.size.width,
            height: layout.usedRect.size.height))
    }

    /// Text layouts are expensive (each runs a full Skia paragraph measurement), and a
    /// single label lays out its text several times per pass — intrinsicContentSize,
    /// the baseline getters, and draw(in:). Cache one layout per containerWidth
    /// (the only per-call variable); the run color is the current textColor, so the
    /// metrics reads (color-independent) and drawing (color matches, so
    /// its paragraph storage is preserved) both reuse the same measured layout. Any
    /// layout- or color-affecting property change clears the cache.
    private var layoutCache: [Double?: TextLayout] = [:]

    private func textLayout(containerWidth: Double?) -> TextLayout {
        if let cached = layoutCache[containerWidth] { return cached }
        let layout = TextLayout(
            runs: [TextRun(
                text: text,
                font: font.scaled(by: uiContext.environment.textScale),
                color: textColor)],
            containerWidth: containerWidth,
            alignment: alignment.textAlignment,
            lineBreakMode: lineBreakMode,
            numberOfLines: numberOfLines,
            textSystem: uiContext.services.textSystem
        )
        layoutCache[containerWidth] = layout
        return layout
    }

    private func invalidateLayoutCache() {
        layoutCache.removeAll(keepingCapacity: true)
    }
}

private extension Label.Alignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading:
            .leading
        case .center:
            .center
        case .trailing:
            .trailing
        }
    }
}
