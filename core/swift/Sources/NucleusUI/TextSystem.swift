import Foundation

public struct TextStyle: Sendable, Equatable {
    public var font: Font
    public var color: Color?
    public var underline: Bool
    public var strikethrough: Bool
    public var link: String?
    public var baselineOffset: Double
    public var emphasis: TextEmphasis
    public var lineHeight: Double?

    public init(
        font: Font,
        color: Color? = nil,
        underline: Bool = false,
        strikethrough: Bool = false,
        link: String? = nil,
        baselineOffset: Double = 0,
        emphasis: TextEmphasis = .none,
        lineHeight: Double? = nil
    ) {
        self.font = font
        self.color = color
        self.underline = underline
        self.strikethrough = strikethrough
        self.link = link
        self.baselineOffset = baselineOffset
        self.emphasis = emphasis
        self.lineHeight = lineHeight.map { max(0, $0) }
    }
}

public enum TextEmphasis: Sendable, Equatable {
    case none
    case emphasized
    case stronglyEmphasized
    case code
}

public enum TextWritingDirection: Sendable, Equatable {
    case natural
    case leftToRight
    case rightToLeft
}

public struct ParagraphStyle: Sendable, Equatable {
    public var alignment: TextAlignment
    public var lineBreakMode: LineBreakMode
    /// Zero means unconstrained.
    public var maximumLineCount: Int
    public var lineSpacing: Double
    public var minimumLineHeight: Double?
    public var maximumLineHeight: Double?
    public var baseWritingDirection: TextWritingDirection
    public var localeIdentifier: String?

    public init(
        alignment: TextAlignment = .leading,
        lineBreakMode: LineBreakMode = .byClipping,
        maximumLineCount: Int = 1,
        lineSpacing: Double = 0,
        minimumLineHeight: Double? = nil,
        maximumLineHeight: Double? = nil,
        baseWritingDirection: TextWritingDirection = .natural,
        localeIdentifier: String? = nil
    ) {
        self.alignment = alignment
        self.lineBreakMode = lineBreakMode
        self.maximumLineCount = max(0, maximumLineCount)
        self.lineSpacing = max(0, lineSpacing)
        self.minimumLineHeight = minimumLineHeight.map { max(0, $0) }
        self.maximumLineHeight = maximumLineHeight.map { max(0, $0) }
        self.baseWritingDirection = baseWritingDirection
        self.localeIdentifier = localeIdentifier
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

/// Opaque token understood only by the backend that created it.
public struct TextLayoutHandle: RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct TextCaretGeometry: Sendable, Equatable {
    public var rect: Rect
    public var direction: TextDirection
    public var affinity: TextAffinity

    public init(
        rect: Rect,
        direction: TextDirection = .leftToRight,
        affinity: TextAffinity = .downstream
    ) {
        self.rect = rect
        self.direction = direction
        self.affinity = affinity
    }
}

/// Metrics and the owning retain returned by one backend layout operation.
///
/// The handle must already carry one retain. NucleusUI transfers that retain
/// into its actor-confined storage and releases it exactly once.
public struct TextBackendLayout: Sendable, Equatable {
    public var handle: TextLayoutHandle
    public var usedRect: Rect
    public var lines: [TextLayoutLine]
    public var didExceedMaximumLineCount: Bool

    public init(
        handle: TextLayoutHandle,
        usedRect: Rect,
        lines: [TextLayoutLine],
        didExceedMaximumLineCount: Bool = false
    ) {
        self.handle = handle
        self.usedRect = usedRect
        self.lines = lines
        self.didExceedMaximumLineCount = didExceedMaximumLineCount
    }
}

/// Pure Swift boundary implemented by the host's text engine.
///
/// Text resources are main-actor confined because layout is authored, queried,
/// registered for drawing, and destroyed as part of the UI scene. A backend may
/// synchronize internally with its renderer, but resource lifetime never
/// escapes onto an arbitrary Swift executor.
@MainActor
public protocol TextLayoutBackend: AnyObject {
    /// Changes when cached layouts must be recreated, such as after font
    /// collection invalidation.
    var generation: UInt64 { get }

    func resolveFont(_ descriptor: FontDescriptor) -> ResolvedFontDescriptor?
    func fontMetrics(for descriptor: FontDescriptor) -> FontMetrics?
    func createLayout(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle,
        scale: Float
    ) -> TextBackendLayout?
    func retainLayout(_ handle: TextLayoutHandle)
    func releaseLayout(_ handle: TextLayoutHandle)
    func glyphPosition(at point: Point, in handle: TextLayoutHandle) -> TextGlyphPosition?
    func caretGeometry(
        atUTF16Offset offset: Int,
        affinity: TextAffinity,
        in handle: TextLayoutHandle
    ) -> TextCaretGeometry?
    func selectionRects(
        forUTF16Range range: Range<Int>,
        in handle: TextLayoutHandle
    ) -> [TextSelectionRect]?
}

public enum TextSystemIssue: Sendable, Equatable {
    case missingBackend
    case fontResolutionFailed(FontDescriptor)
    case fontMetricsFailed(FontDescriptor)
    case layoutFailed
    case resourceCreationFailed
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
        lhs.usedRect == rhs.usedRect
            && lhs.lines == rhs.lines
            && lhs.didExceedMaximumLineCount == rhs.didExceedMaximumLineCount
    }
}

@MainActor
package final class TextLayoutStorage {
    package let handle: TextLayoutHandle
    private let backend: any TextLayoutBackend
    private let installationGeneration: UInt64
    private let backendGeneration: UInt64

    package init(
        handle: TextLayoutHandle,
        backend: any TextLayoutBackend,
        installationGeneration: UInt64
    ) {
        self.handle = handle
        self.backend = backend
        self.installationGeneration = installationGeneration
        self.backendGeneration = backend.generation
    }

    isolated deinit {
        backend.releaseLayout(handle)
    }

    package func isCurrent(in system: TextSystem) -> Bool {
        system.matches(
            backend: backend,
            installationGeneration: installationGeneration,
            backendGeneration: backendGeneration
        )
    }

    package func makeLease() -> TextLayoutLease {
        backend.retainLayout(handle)
        return TextLayoutLease(owning: handle, backend: backend)
    }

    package func glyphPosition(at point: Point) -> TextGlyphPosition? {
        backend.glyphPosition(at: point, in: handle)
    }

    package func caretGeometry(
        atUTF16Offset offset: Int,
        affinity: TextAffinity
    ) -> TextCaretGeometry? {
        backend.caretGeometry(atUTF16Offset: offset, affinity: affinity, in: handle)
    }

    package func selectionRects(forUTF16Range range: Range<Int>) -> [TextSelectionRect]? {
        backend.selectionRects(forUTF16Range: range, in: handle)
    }
}

/// One independently owned retain used by a registered paint recording.
@MainActor
package final class TextLayoutLease {
    package let handle: TextLayoutHandle
    private let backend: any TextLayoutBackend

    package init(owning handle: TextLayoutHandle, backend: any TextLayoutBackend) {
        self.handle = handle
        self.backend = backend
    }

    isolated deinit {
        backend.releaseLayout(handle)
    }
}

@MainActor
public final class TextSystem {
    public typealias DiagnosticHandler = @MainActor @Sendable (TextSystemIssue) -> Void

    public static let shared = TextSystem()

    public private(set) var installationGeneration: UInt64 = 0
    public var diagnosticHandler: DiagnosticHandler?
    package private(set) var layoutRequestCount: UInt64 = 0
    package private(set) var layoutCreationCount: UInt64 = 0
    package private(set) var retainedLayoutHitCount: UInt64 = 0

    private var backend: (any TextLayoutBackend)?
    private var reportedIssues: [TextSystemIssue] = []

    public init() {}

    /// Install the process host's backend. Reinstalling deliberately invalidates
    /// new queries against old cached layouts while their existing resources
    /// remain safely owned by the backend that created them.
    public func installBackend(_ backend: any TextLayoutBackend) {
        self.backend = backend
        installationGeneration &+= 1
        reportedIssues.removeAll(keepingCapacity: true)
    }

    public func removeBackend() {
        backend = nil
        installationGeneration &+= 1
    }

    public var hasInstalledBackend: Bool {
        backend != nil
    }

    public func resolve(_ descriptor: FontDescriptor) -> ResolvedFontDescriptor {
        guard let backend else {
            report(.missingBackend)
            return fallbackResolvedFont(descriptor)
        }
        guard let resolved = backend.resolveFont(descriptor) else {
            report(.fontResolutionFailed(descriptor))
            return fallbackResolvedFont(descriptor)
        }
        return resolved
    }

    public func metrics(for descriptor: FontDescriptor) -> FontMetrics {
        guard let backend else {
            report(.missingBackend)
            return fallbackMetrics(for: descriptor)
        }
        guard let metrics = backend.fontMetrics(for: descriptor) else {
            report(.fontMetricsFailed(descriptor))
            return fallbackMetrics(for: descriptor)
        }
        return metrics
    }

    public func measureWidth(_ text: String, font: Font) -> Double {
        layout(
            AttributedText(text, style: TextStyle(font: font)),
            containerWidth: nil,
            paragraphStyle: ParagraphStyle()
        ).usedRect.size.width
    }

    public func layout(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> TextLayoutResult {
        layoutRequestCount &+= 1
        publishTraceMetrics()
        guard !attributedText.runs.isEmpty else {
            return TextLayoutResult(
                usedRect: Rect(
                    x: 0,
                    y: 0,
                    width: max(0, containerWidth ?? 0),
                    height: 0
                ),
                lines: []
            )
        }
        guard let backend else {
            report(.missingBackend)
            return fallbackLayout(
                attributedText,
                containerWidth: containerWidth,
                paragraphStyle: paragraphStyle
            )
        }
        guard let measured = backend.createLayout(
            attributedText,
            containerWidth: containerWidth,
            paragraphStyle: paragraphStyle,
            scale: 1
        ), measured.handle.rawValue != 0 else {
            report(.layoutFailed)
            return fallbackLayout(
                attributedText,
                containerWidth: containerWidth,
                paragraphStyle: paragraphStyle
            )
        }
        layoutCreationCount &+= 1
        publishTraceMetrics()
        return TextLayoutResult(
            usedRect: measured.usedRect,
            lines: measured.lines,
            didExceedMaximumLineCount: measured.didExceedMaximumLineCount,
            storage: TextLayoutStorage(
                handle: measured.handle,
                backend: backend,
                installationGeneration: installationGeneration
            )
        )
    }

    package func makeLayoutLease(for layout: TextLayout, scale: Float = 1) -> TextLayoutLease? {
        if scale == 1,
           let storage = layout.storage,
           storage.isCurrent(in: self)
        {
            retainedLayoutHitCount &+= 1
            publishTraceMetrics()
            return storage.makeLease()
        }
        guard let backend else {
            report(.missingBackend)
            return nil
        }
        guard let measured = backend.createLayout(
            AttributedText(runs: layout.textRuns),
            containerWidth: layout.containerWidth,
            paragraphStyle: layout.paragraphStyle,
            scale: scale
        ), measured.handle.rawValue != 0 else {
            report(.resourceCreationFailed)
            return nil
        }
        layoutCreationCount &+= 1
        publishTraceMetrics()
        return TextLayoutLease(owning: measured.handle, backend: backend)
    }

    private func publishTraceMetrics() {
        Trace.plot(
            "swift.nucleus.text.layout_requests",
            layoutRequestCount)
        Trace.plot(
            "swift.nucleus.text.layout_creations",
            layoutCreationCount)
        Trace.plot(
            "swift.nucleus.text.retained_layout_hits",
            retainedLayoutHitCount)
    }

    package func matches(
        backend candidate: any TextLayoutBackend,
        installationGeneration candidateInstallation: UInt64,
        backendGeneration candidateBackendGeneration: UInt64
    ) -> Bool {
        guard let backend else { return false }
        return ObjectIdentifier(backend) == ObjectIdentifier(candidate)
            && candidateInstallation == installationGeneration
            && candidateBackendGeneration == backend.generation
    }

    package func fallbackGlyphPosition(
        at point: Point,
        in layout: TextLayout
    ) -> TextGlyphPosition? {
        guard let line = layout.lines.first(where: {
            let minimum = $0.frame.origin.y
            let maximum = minimum + $0.frame.size.height
            return point.y >= minimum && point.y <= maximum
        }) ?? layout.lines.last else {
            return nil
        }
        let count = max(0, line.sourceUTF16Range.count)
        guard count > 0, line.frame.size.width > 0 else {
            return TextGlyphPosition(utf16Offset: line.sourceUTF16Range.lowerBound)
        }
        let fraction = min(
            1,
            max(0, (point.x - line.frame.origin.x) / line.frame.size.width)
        )
        let offset = line.sourceUTF16Range.lowerBound + Int((Double(count) * fraction).rounded())
        return TextGlyphPosition(utf16Offset: offset)
    }

    package func fallbackSelectionRects(
        forUTF16Range range: Range<Int>,
        in layout: TextLayout
    ) -> [TextSelectionRect] {
        guard !range.isEmpty else { return [] }
        return layout.lines.compactMap { line in
            let lower = max(range.lowerBound, line.sourceUTF16Range.lowerBound)
            let upper = min(range.upperBound, line.sourceUTF16Range.upperBound)
            guard lower < upper else { return nil }
            let count = max(1, line.sourceUTF16Range.count)
            let unit = line.frame.size.width / Double(count)
            return TextSelectionRect(rect: Rect(
                x: line.frame.origin.x
                    + Double(lower - line.sourceUTF16Range.lowerBound) * unit,
                y: line.frame.origin.y,
                width: Double(upper - lower) * unit,
                height: line.frame.size.height
            ))
        }
    }

    private func report(_ issue: TextSystemIssue) {
        guard !reportedIssues.contains(issue) else { return }
        reportedIssues.append(issue)
        diagnosticHandler?(issue)
    }

    private func fallbackResolvedFont(_ descriptor: FontDescriptor) -> ResolvedFontDescriptor {
        let family = descriptor.familyName ?? "Nucleus Fallback"
        return ResolvedFontDescriptor(
            familyName: family,
            postScriptName: family,
            pointSize: descriptor.pointSize,
            weight: descriptor.weight,
            width: descriptor.width,
            slant: descriptor.slant
        )
    }

    private func fallbackMetrics(for descriptor: FontDescriptor) -> FontMetrics {
        let size = descriptor.pointSize
        return FontMetrics(
            ascender: size * 0.8,
            descender: size * 0.2,
            leading: size * 0.1,
            capHeight: size * 0.7,
            xHeight: size * 0.5
        )
    }

    private func fallbackLayout(
        _ attributedText: AttributedText,
        containerWidth: Double?,
        paragraphStyle: ParagraphStyle
    ) -> TextLayoutResult {
        let text = attributedText.string
        let font = attributedText.runs.first?.font ?? .systemFont(ofSize: 14)
        let metrics = fallbackMetrics(for: font.descriptor)
        let lineHeight = constrainedLineHeight(
            Double(metrics.lineHeight),
            paragraphStyle: paragraphStyle
        )
        let glyphAdvance = max(1, Double(font.pointSize) * 0.6)
        let naturalWidth = Double(text.utf16.count) * glyphAdvance
        let widthLimit = containerWidth.map { max(0, $0) }
        let canWrap = paragraphStyle.lineBreakMode.isWrapping && (widthLimit ?? 0) > 0
        let unitsPerLine = canWrap
            ? max(1, Int((widthLimit ?? naturalWidth) / glyphAdvance))
            : max(1, text.utf16.count)
        let naturalLineCount = text.isEmpty
            ? 0
            : max(1, Int(ceil(Double(text.utf16.count) / Double(unitsPerLine))))
        let visibleCount = paragraphStyle.maximumLineCount == 0
            ? naturalLineCount
            : min(naturalLineCount, paragraphStyle.maximumLineCount)
        let exceeds = visibleCount < naturalLineCount
        var lines: [TextLayoutLine] = []
        lines.reserveCapacity(visibleCount)
        for lineIndex in 0..<visibleCount {
            let start = lineIndex * unitsPerLine
            let end = min(text.utf16.count, start + unitsPerLine)
            let lineWidth = widthLimit.map { min($0, Double(end - start) * glyphAdvance) }
                ?? Double(end - start) * glyphAdvance
            let x: Double
            switch paragraphStyle.alignment {
            case .leading:
                x = 0
            case .center:
                x = max(0, ((widthLimit ?? lineWidth) - lineWidth) * 0.5)
            case .trailing:
                x = max(0, (widthLimit ?? lineWidth) - lineWidth)
            }
            let range = start..<end
            lines.append(TextLayoutLine(
                text: text.utf16Substring(in: range),
                frame: Rect(
                    x: x,
                    y: Double(lineIndex) * (lineHeight + paragraphStyle.lineSpacing),
                    width: lineWidth,
                    height: lineHeight
                ),
                baselineOffsetFromTop: Double(metrics.firstBaselineOffsetFromTop),
                sourceUTF16Range: range,
                endExcludingWhitespace: end,
                endIncludingNewline: end,
                lineNumber: lineIndex,
                typographicAscent: Double(metrics.ascender),
                typographicDescent: Double(metrics.descender),
                unscaledAscent: Double(metrics.ascender),
                isLastVisibleLine: lineIndex == visibleCount - 1,
                isTruncated: exceeds && lineIndex == visibleCount - 1
            ))
        }
        let usedWidth = widthLimit ?? min(
            naturalWidth,
            lines.map { $0.frame.origin.x + $0.frame.size.width }.max() ?? 0
        )
        let usedHeight = lines.last.map {
            $0.frame.origin.y + $0.frame.size.height
        } ?? 0
        return TextLayoutResult(
            usedRect: Rect(x: 0, y: 0, width: usedWidth, height: usedHeight),
            lines: lines,
            didExceedMaximumLineCount: exceeds
        )
    }

    private func constrainedLineHeight(
        _ natural: Double,
        paragraphStyle: ParagraphStyle
    ) -> Double {
        var result = max(natural, paragraphStyle.minimumLineHeight ?? 0)
        if let maximum = paragraphStyle.maximumLineHeight, maximum > 0 {
            result = min(result, maximum)
        }
        return result
    }
}

private extension LineBreakMode {
    var isWrapping: Bool {
        switch self {
        case .byWordWrapping, .byCharacterWrapping:
            true
        case .byClipping, .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail:
            false
        }
    }
}

private extension String {
    func utf16Substring(in range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, utf16.count))
        let upper = max(lower, min(range.upperBound, utf16.count))
        let start = utf16.index(utf16.startIndex, offsetBy: lower)
        let end = utf16.index(utf16.startIndex, offsetBy: upper)
        guard
            let stringStart = String.Index(start, within: self),
            let stringEnd = String.Index(end, within: self)
        else {
            return ""
        }
        return String(self[stringStart..<stringEnd])
    }
}
import Tracy
