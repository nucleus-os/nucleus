import Foundation
internal import NucleusTextCxxBridge
import Tracy

public struct TextStyle: Sendable, Equatable {
    public var font: Font
    public var color: Color?

    public init(font: Font, color: Color? = nil) {
        self.font = font
        self.color = color
    }
}

public struct ParagraphStyle: Sendable, Equatable {
    public var alignment: TextAlignment
    public var lineBreakMode: LineBreakMode
    public var maximumLineCount: Int

    public init(
        alignment: TextAlignment = .leading,
        lineBreakMode: LineBreakMode = .byClipping,
        maximumLineCount: Int = 1
    ) {
        self.alignment = alignment
        self.lineBreakMode = lineBreakMode
        self.maximumLineCount = max(1, maximumLineCount)
    }
}

public struct TextRun: Sendable, Equatable {
    public var text: String
    public var style: TextStyle

    public var font: Font {
        get { style.font }
        set { style.font = newValue }
    }

    public var color: Color? {
        get { style.color }
        set { style.color = newValue }
    }

    public init(text: String, font: Font, color: Color? = nil) {
        self.text = text
        self.style = TextStyle(font: font, color: color)
    }

    public init(text: String, style: TextStyle) {
        self.text = text
        self.style = style
    }
}

public struct AttributedText: Sendable, Equatable {
    public var runs: [TextRun]

    public var string: String {
        runs.map(\.text).joined()
    }

    public init(_ text: String, style: TextStyle) {
        self.runs = text.isEmpty ? [] : [TextRun(text: text, style: style)]
    }

    public init(runs: [TextRun]) {
        self.runs = runs.filter { !$0.text.isEmpty }
    }
}

public struct TextLayoutResult: Sendable, Equatable {
    public var usedRect: Rect
    public var lines: [TextLayoutLine]
    public var didExceedMaximumLineCount: Bool
    package var storage: TextLayoutStorage?

    public init(
        usedRect: Rect,
        lines: [TextLayoutLine],
        didExceedMaximumLineCount: Bool = false
    ) {
        self.init(
            usedRect: usedRect,
            lines: lines,
            didExceedMaximumLineCount: didExceedMaximumLineCount,
            storage: nil
        )
    }

    package init(
        usedRect: Rect,
        lines: [TextLayoutLine],
        didExceedMaximumLineCount: Bool = false,
        storage: TextLayoutStorage?
    ) {
        self.usedRect = usedRect
        self.lines = lines
        self.didExceedMaximumLineCount = didExceedMaximumLineCount
        self.storage = storage
    }

    public static func == (lhs: TextLayoutResult, rhs: TextLayoutResult) -> Bool {
        lhs.usedRect == rhs.usedRect &&
            lhs.lines == rhs.lines &&
            lhs.didExceedMaximumLineCount == rhs.didExceedMaximumLineCount
    }
}

@_spi(NucleusCompositor) public final class TextLayoutStorage: @unchecked Sendable {
    package let handle: UInt64

    package init(handle: UInt64) {
        self.handle = handle
    }

    deinit {
        if handle != 0 {
            nucleus.text.TextLayoutService().release(handle)
        }
    }

    @_spi(NucleusCompositor) public func retainedHandle() -> UInt64 {
        guard handle != 0 else {
            return 0
        }
        nucleus.text.TextLayoutService().retain(handle)
        return handle
    }

    package func glyphPosition(at point: Point) -> TextGlyphPosition? {
        guard handle != 0 else {
            return nil
        }
        var position = nucleus.text.TextPosition()
        guard nucleus.text.TextLayoutService().glyphPositionAt(handle, Float(point.x), Float(point.y), &position) else {
            return nil
        }
        return TextGlyphPosition(
            utf16Offset: Int(position.utf16Offset),
            affinity: TextAffinity(cValue: position.affinity)
        )
    }

    package func selectionRects(forUTF16Range range: Range<Int>) -> [TextSelectionRect]? {
        guard handle != 0 else {
            return nil
        }
        let start = range.lowerBound.clampedUInt32
        let end = max(range.lowerBound, range.upperBound).clampedUInt32
        var rectCount: UInt32 = 0
        let service = nucleus.text.TextLayoutService()
        guard service.rectsForRange(handle, start, end, nil, 0, &rectCount) else {
            return nil
        }
        guard rectCount > 0 else {
            return []
        }
        var rects = Array(repeating: nucleus.text.TextRect(), count: Int(rectCount))
        let status = rects.withUnsafeMutableBufferPointer { buffer in
            service.rectsForRange(handle, start, end, buffer.baseAddress, buffer.count, &rectCount)
        }
        guard status else {
            return nil
        }
        return rects.prefix(Int(rectCount)).map { rect in
            TextSelectionRect(
                rect: Rect(x: Double(rect.x), y: Double(rect.y), width: Double(rect.width), height: Double(rect.height)),
                direction: TextDirection(cValue: rect.direction)
            )
        }
    }
}

package protocol TextService: Sendable {
    func resolve(_ descriptor: FontDescriptor) -> ResolvedFontDescriptor?
    func metrics(for descriptor: FontDescriptor) -> FontMetrics?
    func measureWidth(_ text: String, font: Font) -> Double?
    func layout(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> TextLayoutResult?
    func makeLayoutHandle(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle,
        scale: Float
    ) -> UInt64
    func releaseLayoutHandle(_ handle: UInt64)
    func glyphPosition(
        at point: Point,
        in attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> TextGlyphPosition?
    func selectionRects(
        forUTF16Range range: Range<Int>,
        in attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> [TextSelectionRect]?
}

package struct SkiaTextService: TextService, Sendable, Equatable {
    package init() {
    }

    package func resolve(_ descriptor: FontDescriptor) -> ResolvedFontDescriptor? {
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

    package func metrics(for descriptor: FontDescriptor) -> FontMetrics? {
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

    package func measureWidth(_ text: String, font: Font) -> Double? {
        let attributedText = AttributedText(text, style: TextStyle(font: font))
        var paragraph = ParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.maximumLineCount = 1
        return layout(attributedText, containerWidth: nil, paragraphStyle: paragraph)?
            .usedRect
            .size
            .width
    }

    package func layout(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> TextLayoutResult? {
        Trace.zone("nucleus.text.layout", color: Trace.Color.green) {
            Trace.plot("swift.nucleus.text.layout.runs", UInt64(attributedText.runs.count))
            guard !attributedText.runs.isEmpty else {
                return TextLayoutResult(usedRect: Rect(x: 0, y: 0, width: max(0, containerWidth ?? 0), height: 0), lines: [])
            }

            var cParagraphStyle = paragraphStyle.cValue(containerWidth: containerWidth)
            return withCTextRuns(attributedText.runs) { cRuns in
                var metrics = nucleus.text.ParagraphMetrics()
                let status = nucleus.text.TextLayoutService().measureRuns(
                    cRuns.baseAddress,
                    cRuns.count,
                    &cParagraphStyle,
                    nil,
                    0,
                    &metrics
                )
                guard status else {
                    return nil
                }

                let lineCapacity = Int(metrics.lineCount)
                guard lineCapacity > 0 else {
                    Trace.plot("swift.nucleus.text.layout.lines", UInt64(0))
                    return TextLayoutResult(
                        usedRect: Rect(x: 0, y: 0, width: Double(metrics.width), height: Double(metrics.height)),
                        lines: [],
                        didExceedMaximumLineCount: metrics.didExceedMaximumLines
                    )
                }

                var lineMetrics = Array(repeating: nucleus.text.TextLineMetrics(), count: lineCapacity)
                metrics = nucleus.text.ParagraphMetrics()
                let metricsStatus = lineMetrics.withUnsafeMutableBufferPointer { buffer in
                    nucleus.text.TextLayoutService().measureRuns(
                        cRuns.baseAddress,
                        cRuns.count,
                        &cParagraphStyle,
                        buffer.baseAddress,
                        buffer.count,
                        &metrics
                    )
                }
                guard metricsStatus else {
                    return nil
                }

                let didExceed = metrics.didExceedMaximumLines
                let sourceText = attributedText.string
                let lines = lineMetrics.enumerated().map { index, line in
                    TextLayoutLine(
                        line,
                        sourceText: sourceText,
                        didExceedMaximumLineCount: didExceed,
                        lineBreakMode: paragraphStyle.lineBreakMode,
                        lineIndex: index,
                        lineCount: lineMetrics.count
                    )
                }
                Trace.plot("swift.nucleus.text.layout.lines", UInt64(lines.count))

                return TextLayoutResult(
                    usedRect: Rect(x: 0, y: 0, width: Double(metrics.width), height: Double(metrics.height)),
                    lines: lines,
                    didExceedMaximumLineCount: metrics.didExceedMaximumLines
                )
            }
        }
    }

    package func makeLayoutHandle(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle,
        scale: Float
    ) -> UInt64 {
        Trace.zone("nucleus.text.make_layout_handle", color: Trace.Color.green) {
            let scaledRuns = attributedText.runs.map { run in
                var font = run.font
                font.pointSize *= scale
                return TextRun(text: run.text, font: font, color: run.color)
            }
            var cParagraphStyle = paragraphStyle.cValue(containerWidth: containerWidth.map { $0 * Double(scale) })

            return withCTextRuns(scaledRuns) { cRuns in
                var handle: UInt64 = 0
                let status = nucleus.text.TextLayoutService().createRuns(
                    cRuns.baseAddress,
                    cRuns.count,
                    &cParagraphStyle,
                    &handle,
                    nil
                )
                guard status, handle != 0 else {
                    return 0
                }
                return handle
            }
        }
    }

    package func releaseLayoutHandle(_ handle: UInt64) {
        guard handle != 0 else {
            return
        }
        nucleus.text.TextLayoutService().release(handle)
    }

    package func glyphPosition(
        at point: Point,
        in attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> TextGlyphPosition? {
        withLayoutHandle(attributedText, containerWidth: containerWidth, paragraphStyle: paragraphStyle) { handle in
            var position = nucleus.text.TextPosition()
            guard nucleus.text.TextLayoutService().glyphPositionAt(handle, Float(point.x), Float(point.y), &position) else {
                return nil
            }
            return TextGlyphPosition(
                utf16Offset: Int(position.utf16Offset),
                affinity: TextAffinity(cValue: position.affinity)
            )
        }
    }

    package func selectionRects(
        forUTF16Range range: Range<Int>,
        in attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> [TextSelectionRect]? {
        withLayoutHandle(attributedText, containerWidth: containerWidth, paragraphStyle: paragraphStyle) { handle in
            let start = range.lowerBound.clampedUInt32
            let end = max(range.lowerBound, range.upperBound).clampedUInt32
            var rectCount: UInt32 = 0
            let service = nucleus.text.TextLayoutService()
            guard service.rectsForRange(handle, start, end, nil, 0, &rectCount) else {
                return nil
            }
            guard rectCount > 0 else {
                return []
            }
            var rects = Array(repeating: nucleus.text.TextRect(), count: Int(rectCount))
            let status = rects.withUnsafeMutableBufferPointer { buffer in
                service.rectsForRange(handle, start, end, buffer.baseAddress, buffer.count, &rectCount)
            }
            guard status else {
                return nil
            }
            return rects.prefix(Int(rectCount)).map { rect in
                TextSelectionRect(
                    rect: Rect(x: Double(rect.x), y: Double(rect.y), width: Double(rect.width), height: Double(rect.height)),
                    direction: TextDirection(cValue: rect.direction)
                )
            }
        }
    }

    private func withLayoutHandle<T>(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle,
        _ body: (UInt64) -> T?
    ) -> T? {
        let handle = makeLayoutHandle(
            attributedText,
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle,
            scale: 1
        )
        guard handle != 0 else {
            return nil
        }
        defer {
            releaseLayoutHandle(handle)
        }
        return body(handle)
    }

}

public struct TextSystem: Sendable, Equatable {
    public static let shared = TextSystem()
    private let service: any TextService

    public init() {
        self.init(service: SkiaTextService())
    }

    package init(service: any TextService) {
        self.service = service
    }

    public func resolve(_ descriptor: FontDescriptor) -> ResolvedFontDescriptor {
        guard let resolved = service.resolve(descriptor) else {
            preconditionFailure("NucleusUI text service failed to resolve font descriptor")
        }
        return resolved
    }

    public func metrics(for descriptor: FontDescriptor) -> FontMetrics {
        guard let metrics = service.metrics(for: descriptor) else {
            preconditionFailure("NucleusUI text service failed to resolve font metrics")
        }
        return metrics
    }

    public func measureWidth(_ text: String, font: Font) -> Double {
        guard let width = service.measureWidth(text, font: font) else {
            preconditionFailure("NucleusUI text service failed to measure text")
        }
        return width
    }

    public func layout(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> TextLayoutResult {
        guard let result = service.layout(
            attributedText,
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle
        ) else {
            preconditionFailure("NucleusUI text service failed to lay out text")
        }
        return result
    }

    public func makeLayoutHandle(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle,
        scale: Float = 1
    ) -> UInt64 {
        let handle = service.makeLayoutHandle(
            attributedText,
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle,
            scale: scale
        )
        guard handle != 0 else {
            preconditionFailure("NucleusUI text service failed to create text layout handle")
        }
        return handle
    }

    @_spi(NucleusCompositor) public func makeLayoutHandle(for layout: TextLayout, scale: Float = 1) -> UInt64 {
        makeLayoutHandle(
            AttributedText(runs: layout.textRuns),
            containerWidth: layout.containerWidth,
            paragraphStyle: ParagraphStyle(
                alignment: layout.alignment,
                lineBreakMode: layout.lineBreakMode,
                maximumLineCount: layout.numberOfLines
            ),
            scale: scale
        )
    }

    public func releaseLayoutHandle(_ handle: UInt64) {
        service.releaseLayoutHandle(handle)
    }

    public func glyphPosition(
        at point: Point,
        in attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> TextGlyphPosition? {
        service.glyphPosition(
            at: point,
            in: attributedText,
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle
        )
    }

    public func selectionRects(
        forUTF16Range range: Range<Int>,
        in attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> [TextSelectionRect] {
        service.selectionRects(
            forUTF16Range: range,
            in: attributedText,
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle
        ) ?? []
    }

    public static func == (lhs: TextSystem, rhs: TextSystem) -> Bool {
        type(of: lhs.service) == type(of: rhs.service)
    }
}

package func withCTextRuns<T>(
    _ runs: [TextRun],
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

    return textBytes.withUnsafeBufferPointer { textBuffer in
        familyBytes.withUnsafeBufferPointer { familyBuffer in
            var cRuns = Array(repeating: nucleus.text.TextRunView(), count: runs.count)
            for index in runs.indices {
                let runColor = runs[index].color ?? Color(1, 1, 1, 1)

                let family = familyOffsets[index]
                cRuns[index].fontFamily = textStringView(
                    base: familyBuffer.baseAddress,
                    offset: family.offset,
                    length: family.length
                )
                let text = textOffsets[index]
                cRuns[index].text = textStringView(
                    base: textBuffer.baseAddress,
                    offset: text.offset,
                    length: text.length
                )
                cRuns[index].pointSize = runs[index].font.pointSize
                cRuns[index].weight = runs[index].font.weight.cValue
                cRuns[index].width = runs[index].font.width.cValue
                cRuns[index].slant = runs[index].font.slant.cValue
                cRuns[index].red = runColor.r
                cRuns[index].green = runColor.g
                cRuns[index].blue = runColor.b
                cRuns[index].alpha = runColor.a
            }
            return cRuns.withUnsafeBufferPointer(body)
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
        paragraph.maximumNumberOfLines = UInt32(max(1, maximumLineCount))
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
        lineCount: Int
    ) {
        let start = Int(metrics.startIndex)
        let end = Int(metrics.endIndex)
        let sourceRange = sourceText.clampedUTF16Range(start: start, end: end)
        let frame = Rect(
            x: Double(metrics.x),
            y: Double(metrics.y),
            width: Double(metrics.width),
            height: Double(metrics.height)
        )
        let isLastVisibleLine = metrics.isLastVisibleLine || lineIndex == lineCount - 1
        self.init(
            text: sourceText.utf16Substring(start: sourceRange.lowerBound, end: sourceRange.upperBound),
            frame: frame,
            baselineOffsetFromTop: Double(metrics.baseline - metrics.y),
            sourceUTF16Range: sourceRange,
            endExcludingWhitespace: sourceText.clampedUTF16Offset(Int(metrics.endExcludingWhitespace)),
            endIncludingNewline: sourceText.clampedUTF16Offset(Int(metrics.endIncludingNewline)),
            lineNumber: Int(metrics.lineNumber),
            typographicAscent: Double(metrics.ascent),
            typographicDescent: Double(metrics.descent),
            unscaledAscent: Double(metrics.unscaledAscent),
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
