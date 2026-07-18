import NucleusLayers

@MainActor
public final class Button: Control, ~Sendable {
    public enum Glyph: Sendable, Equatable {
        case none
        case close
    }

    public var title: String {
        didSet {
            invalidateLayoutCache()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
    public var glyph: Glyph {
        didSet {
            setNeedsDisplay()
        }
    }
    public var foregroundColor: Color {
        didSet {
            if foregroundColor != oldValue { invalidateLayoutCache() }
            setNeedsDisplay()
        }
    }
    public var fontSize: Float {
        didSet {
            invalidateLayoutCache()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    public init(title: String = "") {
        self.title = title
        self.glyph = .none
        self.foregroundColor = Color(1, 1, 1, 1)
        self.fontSize = 14
        super.init()
    }

    public func onPress(_ handler: @escaping (Button) -> Void) {
        onPrimaryAction { [weak self] _ in
            guard let self else { return }
            handler(self)
        }
    }

    public func performPress() {
        _ = handleEvent(Event(type: .action))
    }

    public override var intrinsicContentSize: Size {
        intrinsicContentSizeNeedsUpdate = false
        let layout = titleTextLayout(containerWidth: nil)
        return Size(
            width: max(64, layout.intrinsicSize.width + 24),
            height: max(28, layout.intrinsicSize.height + 10)
        )
    }

    public override func draw(in context: GraphicsContext) {
        switch glyph {
        case .none:
            guard !title.isEmpty else { return }
            let layout = titleTextLayout(containerWidth: Double(frame.size.width))
            let y = max(0, (frame.size.height - layout.usedRect.size.height) * 0.5)
            context.fillColor = foregroundColor
            context.draw(layout, in: Rect(
                x: 0, y: y,
                width: layout.usedRect.size.width,
                height: layout.usedRect.size.height))
        case .close:
            // One stroked path with a round cap, rather than two rects faking
            // strokes. The rects could not express the cap at all.
            let extent = max(0, min(frame.size.width, frame.size.height) * 0.5)
            let centerX = frame.size.width * 0.5
            let centerY = frame.size.height * 0.5
            var path = Path()
            path.move(to: Point(x: centerX - extent, y: centerY - extent))
            path.addLine(to: Point(x: centerX + extent, y: centerY + extent))
            path.move(to: Point(x: centerX + extent, y: centerY - extent))
            path.addLine(to: Point(x: centerX - extent, y: centerY + extent))
            context.strokeColor = foregroundColor
            context.lineWidth = 1.5
            context.lineCap = .round
            context.stroke(path)
        }
    }

    /// One measured title layout per containerWidth, reused across intrinsicContentSize
    /// and displayCommands instead of re-running a Skia paragraph measurement for each.
    /// Built with the current foregroundColor so the color-independent metrics and the
    /// color-matched draw path both reuse it; title/fontSize/foregroundColor changes
    /// clear the cache.
    private var layoutCache: [Double?: TextLayout] = [:]

    private func titleTextLayout(containerWidth: Double?) -> TextLayout {
        if let cached = layoutCache[containerWidth] { return cached }
        let layout = TextLayout(
            runs: [TextRun(text: title, font: Font.systemFont(ofSize: fontSize), color: foregroundColor)],
            containerWidth: containerWidth,
            lineBreakMode: .byTruncatingTail
        )
        layoutCache[containerWidth] = layout
        return layout
    }

    private func invalidateLayoutCache() {
        layoutCache.removeAll(keepingCapacity: true)
    }
}
