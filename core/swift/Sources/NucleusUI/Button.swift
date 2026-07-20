import NucleusLayers

@MainActor
open class Button: Control, ~Sendable {
    public enum Glyph: Sendable, Equatable {
        case none
        case close
    }

    public var title: String {
        didSet {
            guard title != oldValue else { return }
            invalidateLayoutCache()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
    public var glyph: Glyph {
        didSet {
            guard glyph != oldValue else { return }
            setNeedsDisplay()
        }
    }
    public var foregroundColor: Color {
        didSet {
            guard foregroundColor != oldValue else { return }
            invalidateLayoutCache()
            setNeedsDisplay()
        }
    }
    public var fontSize: Float {
        didSet {
            guard fontSize != oldValue else { return }
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
        accessibilityRole = .button
        accessibilityTraits.insert(.button)
    }

    public var isDefaultButton = false {
        didSet { if isDefaultButton != oldValue { setNeedsDisplay() } }
    }

    public override var keyboardActivationKeys: Set<KeyCode> {
        [.space, .return]
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
        }
        super.environmentDidChange(changes)
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
        let layout = titleTextLayout(containerWidth: nil)
        return Size(
            width: max(64, layout.intrinsicSize.width + Button.titleInsetWidth),
            height: max(28, layout.intrinsicSize.height + Button.titleInsetHeight)
        )
    }

    /// Measures its title within the proposed width less the title inset, so a
    /// button in a narrow column grows taller rather than clipping its label.
    public override func measure(_ constraints: LayoutConstraints) -> Size {
        let available = constraints.proposedWidth.map { max(0, $0 - Button.titleInsetWidth) }
        let layout = titleTextLayout(containerWidth: available)
        return constraints.constrain(Size(
            width: max(64, layout.intrinsicSize.width + Button.titleInsetWidth),
            height: max(28, layout.intrinsicSize.height + Button.titleInsetHeight)
        ))
    }

    private static let titleInsetWidth: Double = 24
    private static let titleInsetHeight: Double = 10

    public override func draw(in context: GraphicsContext) {
        drawChrome(in: context)
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

    private func drawChrome(in context: GraphicsContext) {
        let state = controlState
        let color: ColorSpec
        if !state.contains(.enabled) {
            color = .role(.surfaceVariant)
        } else if state.contains(.pressed) || state.contains(.selected) {
            color = .role(.primary)
        } else if state.contains(.hovered) || isDefaultButton {
            color = .role(.hover)
        } else {
            color = .role(.surfaceVariant)
        }
        var path = Path()
        path.addRoundedRect(
            Rect(origin: .zero, size: bounds.size),
            radius: max(6, cornerRadius))
        context.fillColor = resolve(color)
        context.fill(path)
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
            runs: [TextRun(
                text: title,
                font: Font.systemFont(ofSize: fontSize)
                    .scaled(by: uiContext.environment.textScale),
                color: foregroundColor)],
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
