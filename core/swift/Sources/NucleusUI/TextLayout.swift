public enum TextAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

public enum LineBreakMode: Sendable, Equatable {
    case byClipping
    case byTruncatingHead
    case byTruncatingMiddle
    case byTruncatingTail
    case byWordWrapping
    case byCharacterWrapping
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
    public private(set) var text: String
    public private(set) var font: Font
    public private(set) var textRuns: [TextRun]
    public private(set) var containerWidth: Double?
    public private(set) var paragraphStyle: ParagraphStyle
    public private(set) var usedRect: Rect
    public private(set) var lines: [TextLayoutLine]
    public private(set) var didExceedMaximumLineCount: Bool
    package var storage: TextLayoutStorage?

    public var alignment: TextAlignment { paragraphStyle.alignment }
    public var lineBreakMode: LineBreakMode { paragraphStyle.lineBreakMode }
    public var numberOfLines: Int { paragraphStyle.maximumLineCount }

    @MainActor
    public init(
        text: String,
        font: Font,
        containerWidth: Double? = nil,
        alignment: TextAlignment = .leading,
        lineBreakMode: LineBreakMode = .byClipping,
        numberOfLines: Int = 1,
        textSystem: TextSystem
    ) {
        self.text = text
        self.font = font
        self.textRuns = [TextRun(text: text, font: font)]
        self.containerWidth = containerWidth
        self.paragraphStyle = ParagraphStyle(
            alignment: alignment,
            lineBreakMode: lineBreakMode,
            maximumLineCount: numberOfLines
        )

        let result = textSystem.layout(
            AttributedText(text, style: TextStyle(font: font)),
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle
        )
        self.usedRect = result.usedRect
        self.lines = result.lines
        self.didExceedMaximumLineCount = result.didExceedMaximumLineCount
        self.storage = result.storage
    }

    @MainActor
    public init(
        runs: [TextRun],
        containerWidth: Double? = nil,
        alignment: TextAlignment = .leading,
        lineBreakMode: LineBreakMode = .byClipping,
        numberOfLines: Int = 1,
        textSystem: TextSystem
    ) {
        let normalizedRuns = runs.filter { !$0.text.isEmpty }
        let fallbackFont = normalizedRuns.first?.font ?? .systemFont(ofSize: 14)
        self.textRuns = normalizedRuns
        self.text = normalizedRuns.map(\.text).joined()
        self.font = fallbackFont
        self.containerWidth = containerWidth
        self.paragraphStyle = ParagraphStyle(
            alignment: alignment,
            lineBreakMode: lineBreakMode,
            maximumLineCount: numberOfLines
        )

        let result = textSystem.layout(
            AttributedText(runs: normalizedRuns),
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle
        )
        self.usedRect = result.usedRect
        self.lines = result.lines
        self.didExceedMaximumLineCount = result.didExceedMaximumLineCount
        self.storage = result.storage
    }

    @MainActor
    public init(
        attributedText: AttributedText,
        containerWidth: Double? = nil,
        paragraphStyle: ParagraphStyle,
        textSystem: TextSystem
    ) {
        let normalized = AttributedText(runs: attributedText.runs)
        self.textRuns = normalized.runs
        self.text = normalized.string
        self.font = normalized.runs.first?.font ?? .systemFont(ofSize: 14)
        self.containerWidth = containerWidth
        self.paragraphStyle = paragraphStyle

        let result = textSystem.layout(
            normalized,
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle
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
            lhs.paragraphStyle == rhs.paragraphStyle &&
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

    @MainActor
    package func hasBackendResource(
        in textSystem: TextSystem
    ) -> Bool {
        storage?.isCurrent(in: textSystem) == true
    }

    @MainActor
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

    @MainActor
    public static func measureWidth(
        _ text: String,
        font: Font,
        in textSystem: TextSystem
    ) -> Double {
        textSystem.measureWidth(text, font: font)
    }

    @MainActor
    public func glyphPosition(
        at point: Point,
        in textSystem: TextSystem
    ) -> TextGlyphPosition? {
        if let storage,
           storage.isCurrent(in: textSystem),
           let position = storage.glyphPosition(at: point)
        {
            return position
        }
        return textSystem.fallbackGlyphPosition(at: point, in: self)
    }

    @MainActor
    public func caretGeometry(
        atUTF16Offset offset: Int,
        affinity: TextAffinity = .downstream,
        in textSystem: TextSystem
    ) -> TextCaretGeometry? {
        if let storage,
           storage.isCurrent(in: textSystem),
           let geometry = storage.caretGeometry(
               atUTF16Offset: max(0, min(offset, text.utf16.count)),
               affinity: affinity
           )
        {
            return geometry
        }
        let clamped = max(0, min(offset, text.utf16.count))
        if clamped == 0, let first = lines.first {
            return TextCaretGeometry(rect: Rect(
                x: first.frame.origin.x,
                y: first.frame.origin.y,
                width: 1,
                height: first.frame.size.height
            ))
        }
        let rects = textSystem.fallbackSelectionRects(
            forUTF16Range: 0..<clamped,
            in: self
        )
        guard let last = rects.last else { return nil }
        return TextCaretGeometry(
            rect: Rect(
                x: last.rect.origin.x + last.rect.size.width,
                y: last.rect.origin.y,
                width: 1,
                height: last.rect.size.height
            ),
            direction: last.direction
        )
    }

    @MainActor
    public func selectionRects(
        forUTF16Range range: Range<Int>,
        in textSystem: TextSystem
    ) -> [TextSelectionRect] {
        let lower = max(0, min(range.lowerBound, text.utf16.count))
        let upper = max(lower, min(range.upperBound, text.utf16.count))
        let clamped = lower..<upper
        if let storage,
           storage.isCurrent(in: textSystem),
           let rects = storage.selectionRects(forUTF16Range: clamped)
        {
            return rects
        }
        return textSystem.fallbackSelectionRects(
            forUTF16Range: clamped,
            in: self
        )
    }

}
