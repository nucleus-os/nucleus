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

    package override func displayCommands(in dirtyRect: Rect) -> [ViewLayerContentCommand] {
        switch glyph {
        case .none:
            guard !title.isEmpty else {
                return []
            }
            let layout = titleTextLayout(containerWidth: Double(frame.size.width))
            let y = Float(max(0, (frame.size.height - layout.usedRect.size.height) * 0.5))
            return layout.layerContentCommands(color: foregroundColor, y: y)
        case .close:
            let width = Float(frame.size.width)
            let height = Float(frame.size.height)
            let extent = max(0, min(width, height) * 0.5)
            let centerX = width * 0.5
            let centerY = height * 0.5
            return [
                .init(
                    kind: .line,
                    x: centerX - extent,
                    y: centerY - extent,
                    w: centerX + extent,
                    h: centerY + extent,
                    strokeWidth: 1.5,
                    color: foregroundColor
                ),
                .init(
                    kind: .line,
                    x: centerX + extent,
                    y: centerY - extent,
                    w: centerX - extent,
                    h: centerY + extent,
                    strokeWidth: 1.5,
                    color: foregroundColor
                ),
            ]
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
