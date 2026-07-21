import Foundation
internal import NucleusTextCxxBridge
import NucleusUI
import Tracy

/// Skia/SkParagraph implementation of NucleusUI's pure Swift text boundary.
///
/// Hosts install this once at bring-up; merely importing NucleusUI no longer
/// loads a C++ module or silently chooses a native backend.
@MainActor
public final class SkiaTextLayoutBackend: TextLayoutBackend {
    public private(set) var generation: UInt64 = 1

    public init() {}

    public static func install(in system: TextSystem) {
        system.installBackend(SkiaTextLayoutBackend())
    }

    public static func installIfNeeded(in system: TextSystem) {
        guard !system.hasInstalledBackend else { return }
        install(in: system)
    }

    public func invalidateFontCollection() {
        nucleus.text.TextLayoutService().invalidateFontCollection()
        generation &+= 1
    }

    public func resolveFont(_ descriptor: FontDescriptor) -> ResolvedFontDescriptor? {
        let service = nucleus.text.TextLayoutService()
        var resolved = nucleus.text.ResolvedFontDescriptor()
        return withUTF8View(descriptor.familyName) { familyView -> ResolvedFontDescriptor? in
            let status = service.resolveFont(
                familyView,
                descriptor.pointSize,
                descriptor.weight.cValue,
                descriptor.width.cValue,
                descriptor.slant.cValue,
                &resolved
            )
            guard status else {
                return nil
            }
            return ResolvedFontDescriptor(
                familyName: stringFromFixedBuffer(resolved.familyName, count: resolved.familyNameLength),
                postScriptName: stringFromFixedBuffer(
                    resolved.postScriptName,
                    count: resolved.postScriptNameLength
                ),
                pointSize: resolved.pointSize,
                weight: Font.Weight(cValue: resolved.weight),
                width: Font.Width(cValue: resolved.width),
                slant: Font.Slant(cValue: resolved.slant)
            )
        }
    }

    public func fontMetrics(for descriptor: FontDescriptor) -> FontMetrics? {
        let service = nucleus.text.TextLayoutService()
        var metrics = nucleus.text.FontMetrics()
        return withUTF8View(descriptor.familyName) { familyView -> FontMetrics? in
            let status = service.queryFontMetrics(
                familyView,
                descriptor.pointSize,
                descriptor.weight.cValue,
                descriptor.width.cValue,
                descriptor.slant.cValue,
                &metrics
            )
            guard status else {
                return nil
            }
            return FontMetrics(
                ascender: metrics.ascender,
                descender: metrics.descender,
                leading: metrics.leading,
                capHeight: metrics.capHeight,
                xHeight: metrics.xHeight
            )
        }
    }

    public func createLayout(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle,
        scale: Float
    ) -> TextBackendLayout? {
        Trace.zone("nucleus.text.layout", color: Trace.Color.green) {
            Trace.plot("swift.nucleus.text.layout.runs", UInt64(attributedText.runs.count))
            guard !attributedText.runs.isEmpty, scale.isFinite, scale > 0 else {
                return nil
            }
            let scaledRuns = attributedText.runs.map { run in
                var copy = run
                copy.font.pointSize *= scale
                copy.style.baselineOffset *= Double(scale)
                copy.style.lineHeight = copy.style.lineHeight.map {
                    $0 * Double(scale)
                }
                switch copy.style.emphasis {
                case .none:
                    break
                case .emphasized:
                    if copy.font.weight == .regular {
                        copy.font.weight = .semibold
                    }
                case .stronglyEmphasized:
                    copy.font.weight = .bold
                case .code:
                    if copy.font.descriptor.familyName == nil {
                        copy.font.descriptor.familyName = "monospace"
                    }
                }
                return copy
            }
            var scaledParagraph = paragraphStyle
            scaledParagraph.lineSpacing *= Double(scale)
            scaledParagraph.minimumLineHeight = scaledParagraph.minimumLineHeight.map { $0 * Double(scale) }
            scaledParagraph.maximumLineHeight = scaledParagraph.maximumLineHeight.map { $0 * Double(scale) }
            let resolvedRuns = scaledRuns.map { run in
                var copy = run
                var lineHeight = copy.style.lineHeight
                    ?? Double(copy.font.pointSize)
                        + scaledParagraph.lineSpacing
                lineHeight = max(
                    lineHeight,
                    scaledParagraph.minimumLineHeight ?? 0
                )
                if let maximum = scaledParagraph.maximumLineHeight,
                   maximum > 0
                {
                    lineHeight = min(lineHeight, maximum)
                }
                copy.style.lineHeight = lineHeight
                return copy
            }
            var cParagraphStyle = scaledParagraph.cValue(
                containerWidth: containerWidth.map { $0 * Double(scale) }
            )

            return withCTextRuns(
                resolvedRuns,
                localeIdentifier: paragraphStyle.localeIdentifier
            ) { cRuns in
                var handle: UInt64 = 0
                var metrics = nucleus.text.ParagraphMetrics()
                let status = nucleus.text.TextLayoutService().createRuns(
                    cRuns.baseAddress,
                    cRuns.count,
                    &cParagraphStyle,
                    &handle,
                    &metrics
                )
                guard status, handle != 0 else {
                    return nil
                }
                let service = nucleus.text.TextLayoutService()
                let lineCount = Int(metrics.lineCount)
                var lineMetrics = Array(
                    repeating: nucleus.text.TextLineMetrics(),
                    count: lineCount
                )
                if lineCount > 0 {
                    metrics = nucleus.text.ParagraphMetrics()
                    let metricsStatus = lineMetrics.withUnsafeMutableBufferPointer { buffer in
                        service.metrics(
                            handle,
                            buffer.baseAddress,
                            buffer.count,
                            &metrics
                        )
                    }
                    guard metricsStatus else {
                        service.release(handle)
                        return nil
                    }
                }
                let didExceed = metrics.didExceedMaximumLines
                let sourceText = attributedText.string
                let inverseScale = 1 / Double(scale)
                let lines = lineMetrics.enumerated().map { index, line in
                    TextLayoutLine(
                        line,
                        sourceText: sourceText,
                        didExceedMaximumLineCount: didExceed,
                        lineBreakMode: paragraphStyle.lineBreakMode,
                        lineIndex: index,
                        lineCount: lineMetrics.count,
                        coordinateScale: inverseScale
                    )
                }
                Trace.plot("swift.nucleus.text.layout.lines", UInt64(lines.count))
                return TextBackendLayout(
                    handle: TextLayoutHandle(rawValue: handle),
                    usedRect: Rect(
                        x: 0,
                        y: 0,
                        width: Double(metrics.width) * inverseScale,
                        height: Double(metrics.height) * inverseScale
                    ),
                    lines: lines,
                    didExceedMaximumLineCount: didExceed
                )
            }
        }
    }

    public func retainLayout(_ handle: TextLayoutHandle) {
        guard handle.rawValue != 0 else { return }
        nucleus.text.TextLayoutService().retain(handle.rawValue)
    }

    public func releaseLayout(_ handle: TextLayoutHandle) {
        guard handle.rawValue != 0 else { return }
        nucleus.text.TextLayoutService().release(handle.rawValue)
    }

    public func glyphPosition(
        at point: Point,
        in handle: TextLayoutHandle
    ) -> TextGlyphPosition? {
        var position = nucleus.text.TextPosition()
        guard nucleus.text.TextLayoutService().glyphPositionAt(
            handle.rawValue,
            Float(point.x),
            Float(point.y),
            &position
        ) else {
            return nil
        }
        return TextGlyphPosition(
            utf16Offset: Int(position.utf16Offset),
            affinity: TextAffinity(cValue: position.affinity)
        )
    }

    public func caretGeometry(
        atUTF16Offset offset: Int,
        affinity: TextAffinity,
        in handle: TextLayoutHandle
    ) -> TextCaretGeometry? {
        var caret = nucleus.text.TextCaret()
        guard nucleus.text.TextLayoutService().caretForOffset(
            handle.rawValue,
            offset.clampedUInt32,
            affinity.cValue,
            &caret
        ) else {
            return nil
        }
        return TextCaretGeometry(
            rect: Rect(
                x: Double(caret.x),
                y: Double(caret.y),
                width: 1,
                height: Double(caret.height)
            ),
            direction: TextDirection(cValue: caret.direction),
            affinity: TextAffinity(cValue: caret.affinity)
        )
    }

    public func selectionRects(
        forUTF16Range range: Range<Int>,
        in handle: TextLayoutHandle
    ) -> [TextSelectionRect]? {
        let start = range.lowerBound.clampedUInt32
        let end = max(range.lowerBound, range.upperBound).clampedUInt32
        var rectCount: UInt32 = 0
        let service = nucleus.text.TextLayoutService()
        guard service.rectsForRange(
            handle.rawValue,
            start,
            end,
            nil,
            0,
            &rectCount
        ) else {
            return nil
        }
        guard rectCount > 0 else { return [] }
        var rects = Array(repeating: nucleus.text.TextRect(), count: Int(rectCount))
        let status = rects.withUnsafeMutableBufferPointer { buffer in
            service.rectsForRange(
                handle.rawValue,
                start,
                end,
                buffer.baseAddress,
                buffer.count,
                &rectCount
            )
        }
        guard status else { return nil }
        return rects.prefix(Int(rectCount)).map { rect in
            TextSelectionRect(
                rect: Rect(
                    x: Double(rect.x),
                    y: Double(rect.y),
                    width: Double(rect.width),
                    height: Double(rect.height)
                ),
                direction: TextDirection(cValue: rect.direction)
            )
        }
    }
}

package func withCTextRuns<T>(
    _ runs: [TextRun],
    localeIdentifier: String?,
    _ body: (UnsafeBufferPointer<nucleus.text.TextRunView>) -> T
) -> T {
    var textBytes: [UInt8] = []
    var familyBytes: [UInt8] = []
    var textOffsets: [(offset: Int, length: Int)] = []
    var familyOffsets: [(offset: Int, length: Int)] = []

    for run in runs {
        textOffsets.append((textBytes.count, run.text.utf8.count))
        textBytes.append(contentsOf: run.text.utf8)
        let family = run.font.descriptor.familyName ?? ""
        familyOffsets.append((familyBytes.count, family.utf8.count))
        familyBytes.append(contentsOf: family.utf8)
    }

    let localeBytes = Array((localeIdentifier ?? "").utf8)
    return textBytes.withUnsafeBufferPointer { textBuffer in
        familyBytes.withUnsafeBufferPointer { familyBuffer in
            localeBytes.withUnsafeBufferPointer { localeBuffer in
            var cRuns = Array(repeating: nucleus.text.TextRunView(), count: runs.count)
            for index in runs.indices {
                let runColor = runs[index].color ?? Color(1, 1, 1, 1)

                let family = familyOffsets[index]
                cRuns[index].fontFamily = textStringView(
                    base: familyBuffer.baseAddress,
                    offset: family.offset,
                    length: family.length
                )
                cRuns[index].locale = textStringView(
                    base: localeBuffer.baseAddress,
                    offset: 0,
                    length: localeBuffer.count
                )
                let text = textOffsets[index]
                cRuns[index].text = textStringView(
                    base: textBuffer.baseAddress,
                    offset: text.offset,
                    length: text.length
                )
                cRuns[index].pointSize = runs[index].font.pointSize
                cRuns[index].lineHeight = Float(
                    runs[index].style.lineHeight ?? 0
                )
                cRuns[index].baselineShift = Float(
                    runs[index].style.baselineOffset
                )
                cRuns[index].weight = runs[index].font.weight.cValue
                cRuns[index].width = runs[index].font.width.cValue
                cRuns[index].slant = runs[index].font.slant.cValue
                cRuns[index].underline = runs[index].style.underline
                cRuns[index].strikeThrough = runs[index].style.strikethrough
                cRuns[index].red = runColor.r
                cRuns[index].green = runColor.g
                cRuns[index].blue = runColor.b
                cRuns[index].alpha = runColor.a
            }
            return cRuns.withUnsafeBufferPointer(body)
            }
        }
    }
}

package func withUTF8View<T>(_ text: String?, _ body: (nucleus.text.TextStringView) -> T) -> T {
    guard let text, !text.isEmpty else {
        return body(nucleus.text.TextStringView())
    }
    let bytes = Array(text.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        body(textStringView(base: buffer.baseAddress, offset: 0, length: buffer.count))
    }
}

private func textStringView(
    base: UnsafePointer<UInt8>?,
    offset: Int,
    length: Int
) -> nucleus.text.TextStringView {
    guard let base, length > 0 else {
        return nucleus.text.TextStringView()
    }
    var view = nucleus.text.TextStringView()
    view.data = UnsafeRawPointer(base.advanced(by: offset)).assumingMemoryBound(to: CChar.self)
    view.size = length
    return view
}

private func stringFromFixedBuffer<T>(_ buffer: T, count: UInt32) -> String {
    withUnsafeBytes(of: buffer) { rawBuffer in
        let byteCount = min(Int(count), rawBuffer.count)
        return String(decoding: rawBuffer.prefix(byteCount), as: UTF8.self)
    }
}

extension ParagraphStyle {
    package func cValue(containerWidth: Double?) -> nucleus.text.ParagraphStyle {
        var paragraph = nucleus.text.ParagraphStyle()
        paragraph.width = Float(max(0, containerWidth ?? 0))
        paragraph.alignment = alignment.cValue
        paragraph.ellipsizeTail = lineBreakMode == .byTruncatingTail
        paragraph.maximumNumberOfLines = UInt32(max(0, maximumLineCount))
        switch lineBreakMode {
        case .byTruncatingHead:
            paragraph.ellipsisMode = .Start
        case .byTruncatingMiddle:
            paragraph.ellipsisMode = .Middle
        case .byTruncatingTail:
            paragraph.ellipsisMode = .End
        case .byClipping, .byWordWrapping, .byCharacterWrapping:
            paragraph.ellipsisMode = .None
        }
        switch baseWritingDirection {
        case .natural:
            paragraph.direction = .Automatic
        case .leftToRight:
            paragraph.direction = .Ltr
        case .rightToLeft:
            paragraph.direction = .Rtl
        }
        return paragraph
    }
}

extension TextAlignment {
    package var cValue: nucleus.text.TextAlignment {
        switch self {
        case .leading:
            .Leading
        case .center:
            .Center
        case .trailing:
            .Trailing
        }
    }
}

extension TextAffinity {
    package init(cValue: UInt32) {
        self = cValue == nucleus.text.TextAffinityUpstream ? .upstream : .downstream
    }

    package var cValue: UInt32 {
        switch self {
        case .upstream:
            nucleus.text.TextAffinityUpstream
        case .downstream:
            nucleus.text.TextAffinityDownstream
        }
    }
}

extension TextDirection {
    package init(cValue: UInt32) {
        self = cValue == nucleus.text.TextDirectionRtl ? .rightToLeft : .leftToRight
    }
}

private extension TextLayoutLine {
    init(
        _ metrics: nucleus.text.TextLineMetrics,
        sourceText: String,
        didExceedMaximumLineCount: Bool,
        lineBreakMode: LineBreakMode,
        lineIndex: Int,
        lineCount: Int,
        coordinateScale: Double
    ) {
        let start = Int(metrics.startIndex)
        let end = Int(metrics.endIndex)
        let sourceRange = sourceText.clampedUTF16Range(start: start, end: end)
        let frame = Rect(
            x: Double(metrics.x) * coordinateScale,
            y: Double(metrics.y) * coordinateScale,
            width: Double(metrics.width) * coordinateScale,
            height: Double(metrics.height) * coordinateScale
        )
        let isLastVisibleLine = metrics.isLastVisibleLine || lineIndex == lineCount - 1
        self.init(
            text: sourceText.utf16Substring(start: sourceRange.lowerBound, end: sourceRange.upperBound),
            frame: frame,
            baselineOffsetFromTop: Double(metrics.baseline - metrics.y) * coordinateScale,
            sourceUTF16Range: sourceRange,
            endExcludingWhitespace: sourceText.clampedUTF16Offset(Int(metrics.endExcludingWhitespace)),
            endIncludingNewline: sourceText.clampedUTF16Offset(Int(metrics.endIncludingNewline)),
            lineNumber: Int(metrics.lineNumber),
            typographicAscent: Double(metrics.ascent) * coordinateScale,
            typographicDescent: Double(metrics.descent) * coordinateScale,
            unscaledAscent: Double(metrics.unscaledAscent) * coordinateScale,
            isHardBreak: metrics.hardBreak,
            isLastVisibleLine: isLastVisibleLine,
            isTruncated: didExceedMaximumLineCount && isLastVisibleLine && lineBreakMode == .byTruncatingTail
        )
    }
}

package extension Font.Weight {
    init(cValue: UInt32) {
        switch cValue {
        case nucleus.text.FontWeightMedium:
            self = .medium
        case nucleus.text.FontWeightSemibold:
            self = .semibold
        case nucleus.text.FontWeightBold:
            self = .bold
        default:
            self = .regular
        }
    }

    var cValue: UInt32 {
        switch self {
        case .regular:
            nucleus.text.FontWeightRegular
        case .medium:
            nucleus.text.FontWeightMedium
        case .semibold:
            nucleus.text.FontWeightSemibold
        case .bold:
            nucleus.text.FontWeightBold
        }
    }
}

package extension Font.Width {
    init(cValue: UInt32) {
        switch cValue {
        case nucleus.text.FontWidthCompressed:
            self = .compressed
        case nucleus.text.FontWidthCondensed:
            self = .condensed
        case nucleus.text.FontWidthExpanded:
            self = .expanded
        default:
            self = .standard
        }
    }

    var cValue: UInt32 {
        switch self {
        case .compressed:
            nucleus.text.FontWidthCompressed
        case .condensed:
            nucleus.text.FontWidthCondensed
        case .standard:
            nucleus.text.FontWidthStandard
        case .expanded:
            nucleus.text.FontWidthExpanded
        }
    }
}

package extension Font.Slant {
    init(cValue: UInt32) {
        switch cValue {
        case nucleus.text.FontSlantItalic:
            self = .italic
        case nucleus.text.FontSlantOblique:
            self = .oblique
        default:
            self = .upright
        }
    }

    var cValue: UInt32 {
        switch self {
        case .upright:
            nucleus.text.FontSlantUpright
        case .italic:
            nucleus.text.FontSlantItalic
        case .oblique:
            nucleus.text.FontSlantOblique
        }
    }
}

private extension String {
    func clampedUTF16Offset(_ offset: Int) -> Int {
        max(0, min(offset, utf16.count))
    }

    func clampedUTF16Range(start: Int, end: Int) -> Range<Int> {
        let clampedStart = clampedUTF16Offset(start)
        let clampedEnd = max(clampedStart, clampedUTF16Offset(end))
        return clampedStart..<clampedEnd
    }

    func utf16Substring(start: Int, end: Int) -> String {
        let range = clampedUTF16Range(start: start, end: end)
        let clampedStart = range.lowerBound
        let clampedEnd = range.upperBound
        let utf16Start = utf16.index(utf16.startIndex, offsetBy: clampedStart)
        let utf16End = utf16.index(utf16.startIndex, offsetBy: clampedEnd)
        guard
            let stringStart = String.Index(utf16Start, within: self),
            let stringEnd = String.Index(utf16End, within: self)
        else {
            return ""
        }
        return String(self[stringStart..<stringEnd])
    }
}

private extension Int {
    var clampedUInt32: UInt32 {
        UInt32(Swift.max(0, Swift.min(self, Int(UInt32.max))))
    }
}
