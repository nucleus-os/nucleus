/// Stable identity for one paragraph in a retained multiline document.
package struct TextDocumentParagraphID:
    RawRepresentable,
    Hashable,
    Sendable
{
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        precondition(rawValue != 0)
        self.rawValue = rawValue
    }
}

package struct TextDocumentParagraphLayout {
    package var id: TextDocumentParagraphID
    package var revision: UInt64
    package var text: String
    package var utf16Range: Range<Int>
    package var endIncludingNewline: Int
    package var origin: Point
    package var size: Size
    package var layout: TextLayout
}

/// Paragraph-indexed layout above the text backend.
///
/// The document retains only paragraph metadata. Backend layout resources are
/// materialized around the viewport and explicit geometry requests, then
/// evicted by LRU. Local edits preserve unchanged paragraph identity and
/// resources instead of reshaping the complete document.
@MainActor
package final class TextDocumentLayoutStore: ~Sendable {
    package static let maximumCachedParagraphs = 64

    private struct Configuration: Equatable {
        var width: Double?
        var font: Font
        var color: Color
        var wrapsLines: Bool
        var textScale: Double
        var textBackendGeneration: UInt64
        var appearance: Appearance
        var paragraphStyle: ParagraphStyle
    }

    private struct Paragraph {
        var id: TextDocumentParagraphID
        var revision: UInt64
        var text: String
        var utf16Range: Range<Int>
        var endIncludingNewline: Int
        var originY: Double
        var measuredSize: Size?
    }

    private struct CachedLayout {
        var revision: UInt64
        var layout: TextLayout
        var lastAccess: UInt64
    }

    private var configuration: Configuration?
    private var paragraphs: [Paragraph] = []
    private var cache: [TextDocumentParagraphID: CachedLayout] = [:]
    private var nextParagraphID: UInt64 = 1
    private var accessGeneration: UInt64 = 1
    private var lineHeight: Double = 16
    private var documentSizeStorage = Size.zero
    private var documentText = ""
    private var hasDocumentText = false

    package private(set) var layoutCreationCount: UInt64 = 0

    package var documentSize: Size {
        documentSizeStorage
    }

    package var paragraphIDs: [TextDocumentParagraphID] {
        paragraphs.map(\.id)
    }

    package var cachedLayoutCount: Int {
        cache.count
    }

    package var paragraphCount: Int {
        paragraphs.count
    }

    package init() {}

    package func update(
        text: String,
        width: Double?,
        font: Font,
        color: Color,
        wrapsLines: Bool,
        textScale: Double,
        textSystem: TextSystem,
        appearance: Appearance,
        paragraphStyle: ParagraphStyle
    ) {
        let canonicalWidth = width.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        let nextConfiguration = Configuration(
            width: canonicalWidth,
            font: font,
            color: color,
            wrapsLines: wrapsLines,
            textScale: textScale,
            textBackendGeneration: textSystem.installationGeneration,
            appearance: appearance,
            paragraphStyle: paragraphStyle)
        let configurationChanged = configuration != nextConfiguration
        if configurationChanged {
            configuration = nextConfiguration
            cache.removeAll(keepingCapacity: false)
            for index in paragraphs.indices {
                paragraphs[index].measuredSize = nil
            }
            var configuredLineHeight = max(
                1,
                Double(font.metrics(in: textSystem).lineHeight))
            configuredLineHeight += paragraphStyle.lineSpacing
            if let minimum = paragraphStyle.minimumLineHeight {
                configuredLineHeight = max(
                    configuredLineHeight,
                    minimum)
            }
            if let maximum = paragraphStyle.maximumLineHeight {
                configuredLineHeight = min(
                    configuredLineHeight,
                    maximum)
            }
            lineHeight = max(1, configuredLineHeight)
        }
        if !hasDocumentText || documentText != text {
            documentText = text
            hasDocumentText = true
            reconcileParagraphs(with: text)
        }
        recalculateGeometry()
    }

    package func prepare(
        visibleDocumentRect: Rect,
        requiredUTF16Offsets: [Int],
        textSystem: TextSystem
    ) {
        guard !paragraphs.isEmpty else { return }
        var required = Set<Int>()
        if let visibleRange = paragraphIndices(
            intersecting: visibleDocumentRect
        ) {
            let lower = max(0, visibleRange.lowerBound - 2)
            let upper = min(paragraphs.count, visibleRange.upperBound + 2)
            required.formUnion(lower..<upper)
        }
        for offset in requiredUTF16Offsets {
            required.insert(paragraphIndex(containingUTF16: offset))
        }

        // Geometry may change as estimates become real measurements. A second
        // pass makes the visible range exact without unbounded shaping.
        for index in required.sorted() {
            _ = ensureLayout(at: index, textSystem: textSystem)
        }
        recalculateGeometry()

        if let exactRange = paragraphIndices(
            intersecting: visibleDocumentRect
        ) {
            let lower = max(0, exactRange.lowerBound - 2)
            let upper = min(paragraphs.count, exactRange.upperBound + 2)
            for index in lower..<upper {
                required.insert(index)
                _ = ensureLayout(at: index, textSystem: textSystem)
            }
            recalculateGeometry()
        }

        evictLayouts(protecting: Set(required.map {
            paragraphs[$0].id
        }))
    }

    package func visibleLayouts(
        in visibleDocumentRect: Rect,
        requiredUTF16Offsets: [Int],
        textSystem: TextSystem
    ) -> [TextDocumentParagraphLayout] {
        prepare(
            visibleDocumentRect: visibleDocumentRect,
            requiredUTF16Offsets: requiredUTF16Offsets,
            textSystem: textSystem)
        guard let range = paragraphIndices(
            intersecting: visibleDocumentRect
        ) else { return [] }
        return range.compactMap { index in
            guard let layout = ensureLayout(
                at: index,
                textSystem: textSystem)
            else { return nil }
            return snapshot(at: index, layout: layout)
        }
    }

    package func caretRect(
        atUTF16Offset offset: Int,
        affinity: TextAffinity,
        textSystem: TextSystem
    ) -> Rect {
        let index = paragraphIndex(containingUTF16: offset)
        guard let layout = ensureLayout(
            at: index,
            textSystem: textSystem)
        else {
            return Rect(x: 0, y: 0, width: 1, height: lineHeight)
        }
        recalculateGeometry()
        let paragraph = paragraphs[index]
        let localOffset = min(
            max(0, offset - paragraph.utf16Range.lowerBound),
            paragraph.text.utf16.count)
        guard let caret = layout.caretGeometry(
            atUTF16Offset: localOffset,
            affinity: affinity,
            in: textSystem)
        else {
            return Rect(
                x: 0,
                y: paragraph.originY,
                width: 1,
                height: lineHeight)
        }
        return caret.rect.offsetBy(dx: 0, dy: paragraph.originY)
    }

    package func selectionRects(
        forUTF16Range range: Range<Int>,
        textSystem: TextSystem
    ) -> [Rect] {
        guard !range.isEmpty else { return [] }
        var result: [Rect] = []
        let first = paragraphIndex(containingUTF16: range.lowerBound)
        let last = paragraphIndex(
            containingUTF16: max(range.lowerBound, range.upperBound - 1))
        for index in first...last {
            let paragraph = paragraphs[index]
            let lower = max(
                range.lowerBound,
                paragraph.utf16Range.lowerBound)
            let upper = min(
                range.upperBound,
                paragraph.utf16Range.upperBound)
            guard lower < upper,
                  let layout = ensureLayout(
                    at: index,
                    textSystem: textSystem)
            else { continue }
            let localRange = (
                lower - paragraph.utf16Range.lowerBound
            )..<(
                upper - paragraph.utf16Range.lowerBound
            )
            result.append(contentsOf: layout.selectionRects(
                forUTF16Range: localRange,
                in: textSystem
            ).map {
                $0.rect.offsetBy(
                    dx: 0,
                    dy: paragraphs[index].originY)
            })
        }
        recalculateGeometry()
        return result
    }

    package func utf16Offset(
        at documentPoint: Point,
        textSystem: TextSystem
    ) -> Int {
        let index = paragraphIndex(atY: documentPoint.y)
        guard let layout = ensureLayout(
            at: index,
            textSystem: textSystem)
        else {
            return paragraphs[index].utf16Range.lowerBound
        }
        recalculateGeometry()
        let paragraph = paragraphs[index]
        let point = Point(
            x: max(0, documentPoint.x),
            y: max(0, documentPoint.y - paragraph.originY))
        if point.x >= layout.intrinsicSize.width,
           let line = layout.lines.first(where: {
               point.y >= $0.frame.origin.y
                   && point.y < $0.frame.maxY
           })
        {
            return paragraph.utf16Range.lowerBound
                + line.endExcludingWhitespace
        }
        guard let position = layout.glyphPosition(
            at: point,
            in: textSystem)
        else {
            return paragraph.utf16Range.upperBound
        }
        return paragraph.utf16Range.lowerBound
            + min(
                max(0, position.utf16Offset),
                paragraph.text.utf16.count)
    }

    package func lineBoundary(
        atUTF16Offset offset: Int,
        end: Bool,
        textSystem: TextSystem
    ) -> Int {
        let index = paragraphIndex(containingUTF16: offset)
        let paragraph = paragraphs[index]
        guard let layout = ensureLayout(
            at: index,
            textSystem: textSystem),
              !layout.lines.isEmpty
        else {
            return end
                ? paragraph.utf16Range.upperBound
                : paragraph.utf16Range.lowerBound
        }
        let local = min(
            max(0, offset - paragraph.utf16Range.lowerBound),
            paragraph.text.utf16.count)
        let line = layout.lines.first {
            local >= $0.sourceUTF16Range.lowerBound
                && local <= $0.endIncludingNewline
        } ?? layout.lines.last!
        return paragraph.utf16Range.lowerBound
            + (end
                ? line.endExcludingWhitespace
                : line.sourceUTF16Range.lowerBound)
    }

    package func paragraphRange(
        atUTF16Offset offset: Int
    ) -> Range<Int> {
        let paragraph = paragraphs[
            paragraphIndex(containingUTF16: offset)]
        return paragraph.utf16Range.lowerBound..<paragraph.endIncludingNewline
    }

    private func reconcileParagraphs(with text: String) {
        let nextTexts = paragraphStrings(in: text)
        if paragraphs.map(\.text) == nextTexts {
            updateRanges()
            return
        }

        let old = paragraphs
        let commonLimit = min(old.count, nextTexts.count)
        var prefix = 0
        while prefix < commonLimit,
              old[prefix].text == nextTexts[prefix]
        {
            prefix += 1
        }
        var suffix = 0
        while suffix < commonLimit - prefix,
              old[old.count - 1 - suffix].text
                == nextTexts[nextTexts.count - 1 - suffix]
        {
            suffix += 1
        }

        var next: [Paragraph] = []
        next.reserveCapacity(nextTexts.count)
        next.append(contentsOf: old.prefix(prefix))

        let oldMiddle = old.count - prefix - suffix
        let nextMiddle = nextTexts.count - prefix - suffix
        for relativeIndex in 0..<nextMiddle {
            let text = nextTexts[prefix + relativeIndex]
            if relativeIndex < oldMiddle {
                var paragraph = old[prefix + relativeIndex]
                if paragraph.text != text {
                    paragraph.text = text
                    paragraph.revision &+= 1
                    precondition(
                        paragraph.revision != 0,
                        "paragraph revision exhausted")
                    paragraph.measuredSize = nil
                    cache[paragraph.id] = nil
                }
                next.append(paragraph)
            } else {
                next.append(makeParagraph(text: text))
            }
        }
        if suffix > 0 {
            next.append(contentsOf: old.suffix(suffix))
        }

        let retainedIDs = Set(next.map(\.id))
        cache = cache.filter { retainedIDs.contains($0.key) }
        paragraphs = next
        updateRanges()
    }

    private func paragraphStrings(in text: String) -> [String] {
        text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    private func makeParagraph(text: String) -> Paragraph {
        let id = TextDocumentParagraphID(rawValue: nextParagraphID)
        nextParagraphID &+= 1
        precondition(nextParagraphID != 0, "paragraph identity exhausted")
        return Paragraph(
            id: id,
            revision: 1,
            text: text,
            utf16Range: 0..<0,
            endIncludingNewline: 0,
            originY: 0,
            measuredSize: nil)
    }

    private func updateRanges() {
        if paragraphs.isEmpty {
            paragraphs = [makeParagraph(text: "")]
        }
        var offset = 0
        for index in paragraphs.indices {
            let count = paragraphs[index].text.utf16.count
            paragraphs[index].utf16Range = offset..<(offset + count)
            offset += count
            if index < paragraphs.count - 1 {
                offset += 1
            }
            paragraphs[index].endIncludingNewline = offset
        }
    }

    private func ensureLayout(
        at index: Int,
        textSystem: TextSystem
    ) -> TextLayout? {
        guard paragraphs.indices.contains(index),
              let configuration
        else { return nil }
        let paragraph = paragraphs[index]
        accessGeneration &+= 1
        precondition(accessGeneration != 0, "text layout access exhausted")
        if var cached = cache[paragraph.id],
           cached.revision == paragraph.revision
        {
            cached.lastAccess = accessGeneration
            cache[paragraph.id] = cached
            return cached.layout
        }

        let layout = TextLayout(
            attributedText: AttributedText(
                runs: paragraph.text.isEmpty
                    ? []
                    : [TextRun(
                        text: paragraph.text,
                        font: configuration.font,
                        color: configuration.color)]),
            containerWidth: configuration.wrapsLines
                ? configuration.width
                : nil,
            paragraphStyle: configuration.paragraphStyle,
            textSystem: textSystem)
        let measured = Size(
            width: max(0, layout.intrinsicSize.width),
            height: max(lineHeight, layout.intrinsicSize.height))
        paragraphs[index].measuredSize = measured
        cache[paragraph.id] = CachedLayout(
            revision: paragraph.revision,
            layout: layout,
            lastAccess: accessGeneration)
        layoutCreationCount &+= 1
        return layout
    }

    private func recalculateGeometry() {
        guard let configuration else {
            documentSizeStorage = .zero
            return
        }
        let availableWidth = max(1, configuration.width ?? 1)
        let averageGlyphWidth = max(
            1,
            Double(configuration.font.pointSize) * 0.55)
        let charactersPerLine = max(
            1,
            Int((availableWidth / averageGlyphWidth).rounded(.down)))
        var y = 0.0
        var maximumWidth = configuration.wrapsLines
            ? (configuration.width ?? 0)
            : 0
        for index in paragraphs.indices {
            paragraphs[index].originY = y
            let size: Size
            if let measured = paragraphs[index].measuredSize {
                size = measured
            } else {
                let estimatedLines = configuration.wrapsLines
                    ? max(
                        1,
                        Int((
                            Double(max(
                                1,
                                paragraphs[index].text.utf16.count))
                            / Double(charactersPerLine)
                        ).rounded(.up)))
                    : 1
                size = Size(
                    width: configuration.wrapsLines
                        ? (configuration.width ?? 0)
                        : Double(paragraphs[index].text.utf16.count)
                            * averageGlyphWidth,
                    height: lineHeight * Double(estimatedLines))
            }
            y += max(lineHeight, size.height)
            maximumWidth = max(maximumWidth, size.width)
        }
        documentSizeStorage = Size(
            width: max(0, maximumWidth),
            height: max(lineHeight, y))
    }

    private func paragraphIndex(containingUTF16 offset: Int) -> Int {
        guard !paragraphs.isEmpty else { return 0 }
        let clamped = max(0, offset)
        var lower = 0
        var upper = paragraphs.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if paragraphs[middle].endIncludingNewline <= clamped {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return min(lower, paragraphs.count - 1)
    }

    private func paragraphIndex(atY y: Double) -> Int {
        guard !paragraphs.isEmpty else { return 0 }
        let value = max(0, y)
        var lower = 0
        var upper = paragraphs.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let bottom = paragraphs[middle].originY
                + paragraphHeight(at: middle)
            if bottom <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return min(lower, paragraphs.count - 1)
    }

    private func paragraphIndices(
        intersecting rect: Rect
    ) -> Range<Int>? {
        guard !paragraphs.isEmpty,
              rect.size.height > 0,
              rect.maxY >= 0,
              rect.origin.y <= documentSizeStorage.height
        else { return nil }
        let first = paragraphIndex(atY: rect.origin.y)
        let last = paragraphIndex(atY: max(
            rect.origin.y,
            rect.maxY - 0.001))
        return first..<min(paragraphs.count, last + 1)
    }

    private func paragraphHeight(at index: Int) -> Double {
        if let measured = paragraphs[index].measuredSize {
            return max(lineHeight, measured.height)
        }
        guard let configuration else { return lineHeight }
        guard configuration.wrapsLines,
              let width = configuration.width,
              width > 0
        else { return lineHeight }
        let glyphWidth = max(
            1,
            Double(configuration.font.pointSize) * 0.55)
        let perLine = max(1, Int((width / glyphWidth).rounded(.down)))
        let lines = max(
            1,
            Int((
                Double(max(1, paragraphs[index].text.utf16.count))
                / Double(perLine)
            ).rounded(.up)))
        return lineHeight * Double(lines)
    }

    private func snapshot(
        at index: Int,
        layout: TextLayout
    ) -> TextDocumentParagraphLayout {
        let paragraph = paragraphs[index]
        return TextDocumentParagraphLayout(
            id: paragraph.id,
            revision: paragraph.revision,
            text: paragraph.text,
            utf16Range: paragraph.utf16Range,
            endIncludingNewline: paragraph.endIncludingNewline,
            origin: Point(x: 0, y: paragraph.originY),
            size: paragraph.measuredSize ?? Size(
                width: layout.intrinsicSize.width,
                height: max(lineHeight, layout.intrinsicSize.height)),
            layout: layout)
    }

    private func evictLayouts(
        protecting protectedIDs: Set<TextDocumentParagraphID>
    ) {
        guard cache.count > Self.maximumCachedParagraphs else { return }
        let candidates = cache
            .filter { !protectedIDs.contains($0.key) }
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
        let removalCount = min(
            candidates.count,
            cache.count - Self.maximumCachedParagraphs)
        for candidate in candidates.prefix(removalCount) {
            cache[candidate.key] = nil
        }
    }
}

private extension Rect {
    var maxY: Double {
        origin.y + size.height
    }

    func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(
            x: origin.x + dx,
            y: origin.y + dy,
            width: size.width,
            height: size.height)
    }
}
