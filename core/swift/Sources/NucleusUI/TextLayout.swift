public enum TextAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

public enum LineBreakMode: Sendable, Equatable {
    case byClipping
    case byTruncatingTail
    case byWordWrapping
}

public enum TextAffinity: Sendable, Equatable {
    case upstream
    case downstream
}

public enum TextDirection: Sendable, Equatable {
    case leftToRight
    case rightToLeft
}

public struct TextGlyphPosition: Sendable, Equatable {
    public var utf16Offset: Int
    public var affinity: TextAffinity

    public init(utf16Offset: Int, affinity: TextAffinity = .downstream) {
        self.utf16Offset = max(0, utf16Offset)
        self.affinity = affinity
    }
}

public struct TextSelectionRect: Sendable, Equatable {
    public var rect: Rect
    public var direction: TextDirection

    public init(rect: Rect, direction: TextDirection = .leftToRight) {
        self.rect = rect
        self.direction = direction
    }
}

public struct TextLayoutLine: Sendable, Equatable {
    public var text: String
    public var sourceUTF16Range: Range<Int>
    public var endExcludingWhitespace: Int
    public var endIncludingNewline: Int
    public var lineNumber: Int
    public var frame: Rect
    public var baselineOffsetFromTop: Double
    public var typographicAscent: Double
    public var typographicDescent: Double
    public var unscaledAscent: Double
    public var isHardBreak: Bool
    public var isLastVisibleLine: Bool
    public var isTruncated: Bool

    public init(
        text: String,
        frame: Rect,
        baselineOffsetFromTop: Double,
        sourceUTF16Range: Range<Int>? = nil,
        endExcludingWhitespace: Int? = nil,
        endIncludingNewline: Int? = nil,
        lineNumber: Int = 0,
        typographicAscent: Double? = nil,
        typographicDescent: Double? = nil,
        unscaledAscent: Double? = nil,
        isHardBreak: Bool = false,
        isLastVisibleLine: Bool = true,
        isTruncated: Bool = false
    ) {
        self.text = text
        self.sourceUTF16Range = sourceUTF16Range ?? 0..<text.utf16.count
        self.endExcludingWhitespace = endExcludingWhitespace ?? self.sourceUTF16Range.upperBound
        self.endIncludingNewline = endIncludingNewline ?? self.sourceUTF16Range.upperBound
        self.lineNumber = lineNumber
        self.frame = frame
        self.baselineOffsetFromTop = baselineOffsetFromTop
        self.typographicAscent = typographicAscent ?? baselineOffsetFromTop
        self.typographicDescent = typographicDescent ?? max(0, frame.size.height - baselineOffsetFromTop)
        self.unscaledAscent = unscaledAscent ?? self.typographicAscent
        self.isHardBreak = isHardBreak
        self.isLastVisibleLine = isLastVisibleLine
        self.isTruncated = isTruncated
    }

    public var baselineY: Double {
        frame.origin.y + baselineOffsetFromTop
    }
}

public struct TextLayout: Sendable, Equatable {
    public var text: String
    public var font: Font
    public var textRuns: [TextRun]
    public var containerWidth: Double?
    public var alignment: TextAlignment
    public var lineBreakMode: LineBreakMode
    public var numberOfLines: Int
    public var usedRect: Rect
    public var lines: [TextLayoutLine]
    public var didExceedMaximumLineCount: Bool
    @_spi(NucleusCompositor) public var storage: TextLayoutStorage?

    public init(
        text: String,
        font: Font,
        containerWidth: Double? = nil,
        alignment: TextAlignment = .leading,
        lineBreakMode: LineBreakMode = .byClipping,
        numberOfLines: Int = 1
    ) {
        self.text = text
        self.font = font
        self.textRuns = [TextRun(text: text, font: font)]
        self.containerWidth = containerWidth
        self.alignment = alignment
        self.lineBreakMode = lineBreakMode
        self.numberOfLines = max(1, numberOfLines)

        let result = TextSystem.shared.layout(
            AttributedText(text, style: TextStyle(font: font)),
            containerWidth: containerWidth,
            paragraphStyle: ParagraphStyle(
                alignment: alignment,
                lineBreakMode: lineBreakMode,
                maximumLineCount: self.numberOfLines
            )
        )
        self.usedRect = result.usedRect
        self.lines = result.lines
        self.didExceedMaximumLineCount = result.didExceedMaximumLineCount
        self.storage = result.storage
    }

    public init(
        runs: [TextRun],
        containerWidth: Double? = nil,
        alignment: TextAlignment = .leading,
        lineBreakMode: LineBreakMode = .byClipping,
        numberOfLines: Int = 1
    ) {
        let normalizedRuns = runs.filter { !$0.text.isEmpty }
        let fallbackFont = normalizedRuns.first?.font ?? .systemFont(ofSize: 14)
        self.textRuns = normalizedRuns
        self.text = normalizedRuns.map(\.text).joined()
        self.font = fallbackFont
        self.containerWidth = containerWidth
        self.alignment = alignment
        self.lineBreakMode = lineBreakMode
        self.numberOfLines = max(1, numberOfLines)

        let result = TextSystem.shared.layout(
            AttributedText(runs: normalizedRuns),
            containerWidth: containerWidth,
            paragraphStyle: ParagraphStyle(
                alignment: alignment,
                lineBreakMode: lineBreakMode,
                maximumLineCount: self.numberOfLines
            )
        )
        self.usedRect = result.usedRect
        self.lines = result.lines
        self.didExceedMaximumLineCount = result.didExceedMaximumLineCount
        self.storage = result.storage
    }

    public static func == (lhs: TextLayout, rhs: TextLayout) -> Bool {
        lhs.text == rhs.text &&
            lhs.font == rhs.font &&
            lhs.textRuns == rhs.textRuns &&
            lhs.containerWidth == rhs.containerWidth &&
            lhs.alignment == rhs.alignment &&
            lhs.lineBreakMode == rhs.lineBreakMode &&
            lhs.numberOfLines == rhs.numberOfLines &&
            lhs.usedRect == rhs.usedRect &&
            lhs.lines == rhs.lines &&
            lhs.didExceedMaximumLineCount == rhs.didExceedMaximumLineCount
    }

    public var intrinsicSize: Size {
        Size(width: usedRect.size.width, height: usedRect.size.height)
    }

    public var firstBaselineOffsetFromTop: Double {
        lines.first?.baselineOffsetFromTop ?? 0
    }

    public var lastBaselineOffsetFromBottom: Double {
        guard let lastLine = lines.last else {
            return 0
        }
        return max(0, usedRect.size.height - lastLine.baselineY)
    }

    /// Whether this layout has any text to paint.
    public var isEmpty: Bool { textRuns.isEmpty }

    package func applyingDefaultColor(_ color: Color) -> TextLayout {
        var copy = self
        let coloredRuns = textRuns.map { run in
            TextRun(text: run.text, font: run.font, color: run.color ?? color)
        }
        if coloredRuns != textRuns {
            copy.storage = nil
        }
        copy.textRuns = coloredRuns
        return copy
    }

    public static func measureWidth(_ text: String, font: Font) -> Double {
        TextSystem.shared.measureWidth(text, font: font)
    }

    public func glyphPosition(at point: Point) -> TextGlyphPosition? {
        if let storage, let position = storage.glyphPosition(at: point) {
            return position
        }
        return TextSystem.shared.glyphPosition(
            at: point,
            in: AttributedText(runs: textRuns),
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle
        )
    }

    public func selectionRects(forUTF16Range range: Range<Int>) -> [TextSelectionRect] {
        if let storage, let rects = storage.selectionRects(forUTF16Range: range) {
            return rects
        }
        return TextSystem.shared.selectionRects(
            forUTF16Range: range,
            in: AttributedText(runs: textRuns),
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle
        )
    }

    private var paragraphStyle: ParagraphStyle {
        ParagraphStyle(
            alignment: alignment,
            lineBreakMode: lineBreakMode,
            maximumLineCount: numberOfLines
        )
    }
}
