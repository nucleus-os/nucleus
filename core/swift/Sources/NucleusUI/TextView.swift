/// Line layout policy for a multiline editor.
public enum TextViewLineLayout: Sendable, Equatable {
    case wrap
    case horizontal
}

@MainActor
private final class TextContentView: View {
    weak var editor: TextView?

    override func draw(in context: GraphicsContext) {
        editor?.drawDocument(in: context)
    }

    override func handleEvent(_ event: Event) -> EventHandling {
        editor?.handleDocumentEvent(event) ?? .notHandled
    }
}

/// A retained, scrolling multiline text editor.
///
/// `TextView` owns focus, editing state, commands, and input-method lifetime.
/// Its `ScrollView` owns viewport movement; `TextContentView` owns document
/// paint and pointer selection. Paragraph layout is cached independently above
/// the backend, so a local edit does not reshape unrelated paragraphs.
@MainActor
open class TextView:
    Control,
    TextInputClient,
    TextEditingCommandHost,
    RetainedTextEditorAccessibility,
    ~Sendable
{
    public let scrollView = ScrollView()
    private let textContentView = TextContentView()
    private let documentLayout = TextDocumentLayoutStore()

    package var model: TextEditorModel
    private lazy var editingCommands =
        TextEditingCommandCoordinator(host: self)

    private var preeditStyles: [TextInputPreeditSpan] = []
    private var selectionDragAnchor: Int?
    private var preferredCaretX: Double?
    private var caretPhaseStartNs: UInt64 = 0
    private var caretVisibleOverride: Bool?

    public var stringValue: String {
        get { model.text }
        set {
            guard newValue != model.text else { return }
            var replacement = TextEditorModel(text: newValue)
            replacement.maximumLength = model.maximumLength
            model = replacement
            editingCommands.advanceGeneration()
            documentDidChange()
            notifyInputMethodOfStateChange()
            recordMutation(.accessibility)
            onChange?(self)
        }
    }

    public var maximumLength: Int? {
        get { model.maximumLength }
        set { model.maximumLength = newValue }
    }

    public var placeholderString: String = "" {
        didSet {
            guard placeholderString != oldValue else { return }
            textContentView.setNeedsDisplay()
        }
    }

    public var font: Font = .systemFont(ofSize: 13) {
        didSet {
            guard font != oldValue else { return }
            documentConfigurationDidChange()
        }
    }

    public var textColor = Color(1, 1, 1, 1) {
        didSet {
            guard textColor != oldValue else { return }
            documentConfigurationDidChange()
        }
    }

    public var placeholderColor = Color(1, 1, 1, 0.4) {
        didSet {
            guard placeholderColor != oldValue else { return }
            textContentView.setNeedsDisplay()
        }
    }

    public var selectionColor = Color(0.24, 0.51, 0.92, 0.55) {
        didSet {
            guard selectionColor != oldValue else { return }
            textContentView.setNeedsDisplay()
        }
    }

    public var caretColor = Color(1, 1, 1, 1) {
        didSet {
            guard caretColor != oldValue else { return }
            textContentView.setNeedsDisplay()
        }
    }

    public var textInsets = EdgeInsets(
        top: 6,
        left: 6,
        bottom: 6,
        right: 6
    ) {
        didSet {
            guard textInsets != oldValue else { return }
            documentConfigurationDidChange()
        }
    }

    public var lineLayout: TextViewLineLayout = .wrap {
        didSet {
            guard lineLayout != oldValue else { return }
            syncScrollPolicy()
            documentConfigurationDidChange()
        }
    }

    public var paragraphStyle = ParagraphStyle(
        alignment: .leading,
        lineBreakMode: .byWordWrapping,
        maximumLineCount: 0
    ) {
        didSet {
            guard paragraphStyle != oldValue else { return }
            documentConfigurationDidChange()
        }
    }

    public var allowsVerticalScrolling = true {
        didSet {
            guard allowsVerticalScrolling != oldValue else { return }
            syncScrollPolicy()
        }
    }

    public var allowsHorizontalScrolling = true {
        didSet {
            guard allowsHorizontalScrolling != oldValue else { return }
            syncScrollPolicy()
        }
    }

    public var showsScrollIndicators: ScrollIndicators = .vertical {
        didSet {
            scrollView.indicators = showsScrollIndicators
        }
    }

    public var minimumVisibleLineCount = 3 {
        didSet {
            if minimumVisibleLineCount < 1 {
                minimumVisibleLineCount = 1
                return
            }
            invalidateIntrinsicContentSize()
        }
    }

    public var contentType: TextInputContentType = .normal
    public var hints: TextInputHints = [
        .spellcheck,
        .autocorrect,
        .multiline,
    ]
    public private(set) var inputLanguage: String?

    public var onChange: ((TextView) -> Void)?
    public var onSubmit: ((TextView) -> Void)?

    public init(string: String = "") {
        model = TextEditorModel(text: string)
        super.init()
        model.setCaret(at: model.utf16Count)
        accessibilityRole = .textArea
        var traits = accessibilityTraits
        traits.formUnion([.editable, .multiline])
        accessibilityTraits = traits
        textContentView.editor = self
        scrollView.documentView = textContentView
        scrollView.onInternalScroll = { [weak self] _ in
            self?.prepareVisibleParagraphLayouts()
            self?.textContentView.setNeedsDisplay()
        }
        addSubview(scrollView)
        scrollView.indicators = showsScrollIndicators
        syncScrollPolicy()
        editingCommands.installStandardActions(on: self)
        updateDocumentLayout()
    }

    open override var acceptsFirstResponder: Bool {
        isEnabled
    }

    open override var environmentDependencies: UIEnvironmentChanges {
        super.environmentDependencies.union([
            .textScale,
            .appearance,
        ])
    }

    open override func environmentDidChange(
        _ changes: UIEnvironmentChanges
    ) {
        if !changes.intersection([.textScale, .appearance]).isEmpty {
            documentConfigurationDidChange()
        }
        super.environmentDidChange(changes)
    }

    open override var intrinsicContentSize: Size {
        let lineHeight = Double(
            font.metrics(in: uiContext.services.textSystem).lineHeight)
        return Size(
            width: 160,
            height: max(
                1,
                lineHeight * Double(minimumVisibleLineCount)
                    + textInsets.top + textInsets.bottom))
    }

    open override func measure(
        _ constraints: LayoutConstraints
    ) -> Size {
        constraints.constrain(intrinsicContentSize)
    }

    open override func layout() {
        scrollView.frame = Rect(origin: .zero, size: bounds.size)
        scrollView.layoutIfNeeded()
        updateDocumentLayout()
        syncDocumentFrame()
        revealCaret()
    }

    public var contentOffset: Point {
        get { scrollView.contentOffset }
        set { scrollView.contentOffset = newValue }
    }

    public var contentSize: Size {
        textContentView.frame.size
    }

    public var viewportSize: Size {
        scrollView.clipView.frame.size
    }

    open override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        editingCommands.advanceGeneration()
        window?.textInputContext.activate(self)
        restartCaretBlink()
        revealCaret()
        textContentView.setNeedsDisplay()
        return true
    }

    open override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        editingCommands.cancelAndAdvance()
        if model.hasMarkedText {
            model.unmarkText()
            documentDidChange()
        }
        model.closeUndoGroup()
        window?.textInputContext.deactivate(self)
        textContentView.setNeedsDisplay()
        return true
    }

    open override func retainedHierarchyWillDetach() {
        editingCommands.cancelAndAdvance()
        super.retainedHierarchyWillDetach()
    }

    public func selectAllText() {
        model.selectAll()
        afterSelectionChange(resetPreferredX: true)
    }

    public func setSelectedRange(_ range: Range<Int>) {
        model.setSelection(TextSelection(
            anchor: range.lowerBound,
            head: range.upperBound))
        afterSelectionChange(resetPreferredX: true)
    }

    public func copySelection() async -> Bool {
        await editingCommands.copy(to: uiContext.services.pasteboard)
    }

    public func copySelection(to pasteboard: Pasteboard) async -> Bool {
        await editingCommands.copy(to: pasteboard)
    }

    public func cutSelection() async -> Bool {
        await editingCommands.cut(to: uiContext.services.pasteboard)
    }

    public func cutSelection(to pasteboard: Pasteboard) async -> Bool {
        await editingCommands.cut(to: pasteboard)
    }

    public func paste() async -> Bool {
        await editingCommands.paste(from: uiContext.services.pasteboard)
    }

    public func paste(from pasteboard: Pasteboard) async -> Bool {
        await editingCommands.paste(from: pasteboard)
    }

    public func discardUndoHistory() {
        model.discardUndoHistory()
    }

    public var isCaretVisible: Bool {
        isFocused
            && model.selection.isCollapsed
            && (caretVisibleOverride ?? true)
    }

    public func advanceCaretBlink(nowNs: UInt64) {
        guard isFocused else { return }
        let elapsed = nowNs &- caretPhaseStartNs
        let visible =
            (elapsed / 530_000_000) % 2 == 0
        if visible != caretVisibleOverride {
            caretVisibleOverride = visible
            textContentView.setNeedsDisplay()
        }
    }

    /// Caret geometry in this editor's coordinate system.
    public var caretRect: Rect {
        textContentView.convert(caretDocumentRect, to: self)
    }

    /// Text range geometry in the editor's coordinate system. Offscreen ranges
    /// remain queryable and naturally return coordinates outside the viewport.
    public func accessibilityRects(
        forUTF16Range range: Range<Int>
    ) -> [Rect] {
        updateDocumentLayout()
        return documentLayout.selectionRects(
            forUTF16Range: range,
            textSystem: uiContext.services.textSystem
        ).map {
            textContentView.convert(
                offsetForInsets($0),
                to: self)
        }
    }

    package var paragraphIDs: [TextDocumentParagraphID] {
        documentLayout.paragraphIDs
    }

    package var cachedParagraphLayoutCount: Int {
        documentLayout.cachedLayoutCount
    }

    package var paragraphLayoutCreationCount: UInt64 {
        documentLayout.layoutCreationCount
    }

    package func prepareVisibleParagraphLayouts() {
        updateDocumentLayout()
        documentLayout.prepare(
            visibleDocumentRect: visibleLayoutRect,
            requiredUTF16Offsets: [
                model.selection.anchor,
                model.selection.head,
            ],
            textSystem: uiContext.services.textSystem)
        syncDocumentFrame()
    }

    // MARK: - Document content

    fileprivate func drawDocument(in context: GraphicsContext) {
        updateDocumentLayout()
        let visible = visibleLayoutRect
        let required = [
            model.selection.anchor,
            model.selection.head,
        ]
        let paragraphs = documentLayout.visibleLayouts(
            in: visible,
            requiredUTF16Offsets: required,
            textSystem: uiContext.services.textSystem)
        syncDocumentFrame()

        if !model.selection.isCollapsed {
            context.fillColor = selectionColor
            for rect in documentLayout.selectionRects(
                forUTF16Range: model.selection.range,
                textSystem: uiContext.services.textSystem)
            {
                var path = Path()
                path.addRect(offsetForInsets(rect))
                context.fill(path)
            }
        }

        if model.isEmpty, !placeholderString.isEmpty, !isFocused {
            let placeholder = TextLayout(
                text: placeholderString,
                font: scaledFont,
                containerWidth: layoutWidth,
                alignment: .leading,
                lineBreakMode: .byWordWrapping,
                numberOfLines: 0,
                textSystem: uiContext.services.textSystem)
            context.fillColor = placeholderColor
            context.draw(
                placeholder,
                in: Rect(
                    origin: Point(
                        x: textInsets.left,
                        y: textInsets.top),
                    size: placeholder.usedRect.size))
        } else {
            context.fillColor = textColor
            for paragraph in paragraphs where !paragraph.layout.isEmpty {
                context.draw(
                    paragraph.layout,
                    in: Rect(
                        origin: Point(
                            x: textInsets.left,
                            y: textInsets.top
                                + paragraph.origin.y),
                        size: paragraph.layout.usedRect.size))
            }
        }

        drawMarkedText(in: context)
        if isCaretVisible {
            context.fillColor = caretColor
            var caret = Path()
            caret.addRect(caretDocumentRect)
            context.fill(caret)
        }
    }

    fileprivate func handleDocumentEvent(
        _ event: Event
    ) -> EventHandling {
        guard isEnabled else { return .notHandled }
        switch event.type {
        case .pointerDown:
            guard event.button == .left else { return .notHandled }
            if !isFocused {
                _ = window?.makeFirstResponder(self)
            }
            let offset = documentOffset(at: event.location)
            switch event.clickCount {
            case 2:
                selectWord(containing: offset)
            case 3:
                selectLine(containing: offset)
            case let count where count >= 4:
                selectParagraph(containing: offset)
            default:
                if event.modifierFlags.contains(.shift) {
                    model.setSelection(TextSelection(
                        anchor: model.selection.anchor,
                        head: offset))
                } else {
                    model.setCaret(at: offset)
                }
                selectionDragAnchor = model.selection.anchor
                afterSelectionChange(resetPreferredX: true)
            }
            return .handled
        case .pointerDragged:
            guard let selectionDragAnchor else { return .notHandled }
            autoscrollSelection(toward: event.location)
            model.setSelection(TextSelection(
                anchor: selectionDragAnchor,
                head: documentOffset(at: event.location)))
            afterSelectionChange(resetPreferredX: true)
            return .handled
        case .pointerUp:
            selectionDragAnchor = nil
            return .handled
        default:
            return .notHandled
        }
    }

    open override func handleEvent(_ event: Event) -> EventHandling {
        guard isEnabled else { return .notHandled }
        guard event.type == .keyDown else {
            return super.handleEvent(event)
        }
        return handleKeyDown(event)
    }

    private func handleKeyDown(_ event: Event) -> EventHandling {
        let byWord = event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.control)
        let extending = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)

        switch event.keyCode {
        case .leftArrow:
            if command {
                setCaret(
                    at: documentLayout.lineBoundary(
                        atUTF16Offset: model.selection.head,
                        end: false,
                        textSystem: uiContext.services.textSystem),
                    extendingSelection: extending,
                    resetPreferredX: true)
            } else {
                model.moveCaret(
                    byWord ? .wordBackward : .backward,
                    extendingSelection: extending)
                afterSelectionChange(resetPreferredX: true)
            }
            return .handled
        case .rightArrow:
            if command {
                setCaret(
                    at: documentLayout.lineBoundary(
                        atUTF16Offset: model.selection.head,
                        end: true,
                        textSystem: uiContext.services.textSystem),
                    extendingSelection: extending,
                    resetPreferredX: true)
            } else {
                model.moveCaret(
                    byWord ? .wordForward : .forward,
                    extendingSelection: extending)
                afterSelectionChange(resetPreferredX: true)
            }
            return .handled
        case .upArrow:
            if command {
                setCaret(
                    at: 0,
                    extendingSelection: extending,
                    resetPreferredX: true)
            } else {
                moveCaretVertically(
                    by: -verticalCaretStep,
                    extendingSelection: extending)
            }
            return .handled
        case .downArrow:
            if command {
                setCaret(
                    at: model.utf16Count,
                    extendingSelection: extending,
                    resetPreferredX: true)
            } else {
                moveCaretVertically(
                    by: verticalCaretStep,
                    extendingSelection: extending)
            }
            return .handled
        case .pageUp:
            moveCaretVertically(
                by: -max(verticalCaretStep, viewportSize.height),
                extendingSelection: extending)
            return .handled
        case .pageDown:
            moveCaretVertically(
                by: max(verticalCaretStep, viewportSize.height),
                extendingSelection: extending)
            return .handled
        case .home:
            let offset = command
                ? 0
                : documentLayout.lineBoundary(
                    atUTF16Offset: model.selection.head,
                    end: false,
                    textSystem: uiContext.services.textSystem)
            setCaret(
                at: offset,
                extendingSelection: extending,
                resetPreferredX: true)
            return .handled
        case .end:
            let offset = command
                ? model.utf16Count
                : documentLayout.lineBoundary(
                    atUTF16Offset: model.selection.head,
                    end: true,
                    textSystem: uiContext.services.textSystem)
            setCaret(
                at: offset,
                extendingSelection: extending,
                resetPreferredX: true)
            return .handled
        case .delete:
            if byWord {
                model.deleteWordBackward()
            } else {
                model.deleteBackward()
            }
            afterEdit()
            return .handled
        case .forwardDelete:
            if byWord {
                model.deleteWordForward()
            } else {
                model.deleteForward()
            }
            afterEdit()
            return .handled
        case .return:
            model.insert("\n")
            afterEdit()
            return .handled
        case .escape:
            guard model.hasMarkedText else { return .notHandled }
            model.unmarkText()
            afterEdit()
            return .handled
        default:
            break
        }

        if command, let characters = event.characters?.lowercased() {
            let action: ActionID? = switch characters {
            case "a": .selectAll
            case "c": .copy
            case "x": .cut
            case "v": .paste
            case "z":
                event.modifierFlags.contains(.shift) ? .redo : .undo
            default: nil
            }
            guard let action else { return .notHandled }
            return performAction(action, event: event)
                ? .handled
                : .notHandled
        }

        guard let characters = event.characters,
              !characters.isEmpty
        else { return .notHandled }
        model.insert(characters)
        afterEdit()
        return .handled
    }

    private func selectWord(containing offset: Int) {
        var probe = model
        probe.setCaret(at: offset)
        probe.moveCaret(.wordForward)
        let end = probe.selection.head
        probe.moveCaret(.wordBackward)
        model.setSelection(TextSelection(
            anchor: probe.selection.head,
            head: end))
        afterSelectionChange(resetPreferredX: true)
    }

    private func selectLine(containing offset: Int) {
        let start = documentLayout.lineBoundary(
            atUTF16Offset: offset,
            end: false,
            textSystem: uiContext.services.textSystem)
        let end = documentLayout.lineBoundary(
            atUTF16Offset: offset,
            end: true,
            textSystem: uiContext.services.textSystem)
        model.setSelection(TextSelection(anchor: start, head: end))
        afterSelectionChange(resetPreferredX: true)
    }

    private func selectParagraph(containing offset: Int) {
        let range = documentLayout.paragraphRange(
            atUTF16Offset: offset)
        model.setSelection(TextSelection(
            anchor: range.lowerBound,
            head: range.upperBound))
        afterSelectionChange(resetPreferredX: true)
    }

    private func moveCaretVertically(
        by deltaY: Double,
        extendingSelection: Bool
    ) {
        updateDocumentLayout()
        let caret = caretDocumentRect
        let x = preferredCaretX ?? caret.origin.x
        preferredCaretX = x
        let target = Point(
            x: x - textInsets.left,
            y: caret.origin.y - textInsets.top + deltaY)
        let offset = documentLayout.utf16Offset(
            at: target,
            textSystem: uiContext.services.textSystem)
        setCaret(
            at: offset,
            extendingSelection: extendingSelection,
            resetPreferredX: false)
    }

    private func setCaret(
        at offset: Int,
        extendingSelection: Bool,
        resetPreferredX: Bool
    ) {
        if extendingSelection {
            model.setSelection(TextSelection(
                anchor: model.selection.anchor,
                head: offset))
        } else {
            model.setCaret(at: offset)
        }
        afterSelectionChange(resetPreferredX: resetPreferredX)
    }

    private var verticalCaretStep: Double {
        max(
            1,
            caretDocumentRect.size.height)
    }

    private func afterEdit(
        cause: TextInputChangeCause = .other
    ) {
        editingCommands.advanceGeneration()
        preferredCaretX = nil
        documentDidChange()
        restartCaretBlink()
        notifyInputMethodOfStateChange(cause: cause)
        recordMutation(.accessibility)
        onChange?(self)
    }

    private func afterSelectionChange(resetPreferredX: Bool) {
        editingCommands.advanceGeneration()
        if resetPreferredX {
            preferredCaretX = nil
        }
        restartCaretBlink()
        revealCaret()
        notifyInputMethodOfStateChange()
        recordMutation(.accessibility)
        textContentView.setNeedsDisplay()
    }

    private func documentDidChange() {
        updateDocumentLayout()
        syncDocumentFrame()
        revealCaret()
        invalidateIntrinsicContentSize()
        textContentView.setNeedsDisplay()
    }

    private func documentConfigurationDidChange() {
        updateDocumentLayout()
        syncDocumentFrame()
        setNeedsLayout()
        revealCaret()
        invalidateIntrinsicContentSize()
        textContentView.setNeedsDisplay()
    }

    private func updateDocumentLayout() {
        documentLayout.update(
            text: model.text,
            width: layoutWidth,
            font: scaledFont,
            color: textColor,
            wrapsLines: lineLayout == .wrap,
            textScale: uiContext.environment.textScale,
            textSystem: uiContext.services.textSystem,
            appearance: uiContext.environment.appearance,
            paragraphStyle: effectiveParagraphStyle)
    }

    private var scaledFont: Font {
        font.scaled(by: uiContext.environment.textScale)
    }

    private var effectiveParagraphStyle: ParagraphStyle {
        var style = paragraphStyle
        style.maximumLineCount = 0
        style.lineBreakMode = lineLayout == .wrap
            ? .byWordWrapping
            : .byClipping
        return style
    }

    private var layoutWidth: Double? {
        guard lineLayout == .wrap else { return nil }
        let viewportWidth = scrollView.clipView.frame.size.width > 0
            ? scrollView.clipView.frame.size.width
            : bounds.size.width
        let width = viewportWidth
            - textInsets.left
            - textInsets.right
        return width > 0 ? width : nil
    }

    private func syncDocumentFrame() {
        let viewport = scrollView.clipView.frame.size
        let document = documentLayout.documentSize
        let width = max(
            viewport.width,
            document.width + textInsets.left + textInsets.right)
        let height = max(
            viewport.height,
            document.height + textInsets.top + textInsets.bottom)
        let frame = Rect(
            x: 0,
            y: 0,
            width: width,
            height: height)
        if textContentView.frame != frame {
            textContentView.frame = frame
            scrollView.clampScrollPosition()
        }
    }

    private func syncScrollPolicy() {
        var axes: ScrollIndicators = []
        if allowsVerticalScrolling {
            axes.insert(.vertical)
        }
        if allowsHorizontalScrolling, lineLayout == .horizontal {
            axes.insert(.horizontal)
        }
        scrollView.scrollableAxes = axes
    }

    private var visibleLayoutRect: Rect {
        Rect(
            x: max(0, scrollView.contentOffset.x - textInsets.left),
            y: max(0, scrollView.contentOffset.y - textInsets.top),
            width: scrollView.clipView.frame.size.width,
            height: scrollView.clipView.frame.size.height)
    }

    private var caretDocumentRect: Rect {
        updateDocumentLayout()
        let rect = documentLayout.caretRect(
            atUTF16Offset: model.selection.head,
            affinity: model.affinity,
            textSystem: uiContext.services.textSystem)
        syncDocumentFrame()
        return offsetForInsets(rect)
    }

    private func offsetForInsets(_ rect: Rect) -> Rect {
        Rect(
            x: rect.origin.x + textInsets.left,
            y: rect.origin.y + textInsets.top,
            width: rect.size.width,
            height: rect.size.height)
    }

    private func documentOffset(at point: Point) -> Int {
        updateDocumentLayout()
        return documentLayout.utf16Offset(
            at: Point(
                x: point.x - textInsets.left,
                y: point.y - textInsets.top),
            textSystem: uiContext.services.textSystem)
    }

    private func revealCaret() {
        guard bounds.size.width > 0, bounds.size.height > 0 else {
            return
        }
        _ = scrollView.scrollToVisible(
            caretDocumentRect.insetBy(dx: -2, dy: -2))
    }

    private func autoscrollSelection(toward point: Point) {
        let visible = Rect(
            origin: scrollView.contentOffset,
            size: scrollView.clipView.frame.size)
        var offset = scrollView.contentOffset
        let step: Double = 24
        if point.x < visible.origin.x {
            offset.x -= step
        } else if point.x > visible.origin.x + visible.size.width {
            offset.x += step
        }
        if point.y < visible.origin.y {
            offset.y -= step
        } else if point.y > visible.origin.y + visible.size.height {
            offset.y += step
        }
        scrollView.contentOffset = offset
    }

    private func restartCaretBlink() {
        caretPhaseStartNs = 0
        caretVisibleOverride = true
    }

    private func drawMarkedText(in context: GraphicsContext) {
        guard let markedRange = model.markedRange else { return }
        let spans = preeditStyles.isEmpty
            ? [TextInputPreeditSpan(
                range: 0..<markedRange.count,
                style: .active)]
            : preeditStyles
        for span in spans {
            let lower = markedRange.lowerBound
                + min(max(0, span.range.lowerBound), markedRange.count)
            let upper = markedRange.lowerBound
                + min(max(0, span.range.upperBound), markedRange.count)
            guard lower < upper else { continue }
            context.fillColor = span.style == .incorrect
                ? Color(0.95, 0.25, 0.25, 0.9)
                : textColor.opacity(
                    span.style == .inactive ? 0.45 : 0.7)
            let thickness: Double =
                span.style == .selected
                    || span.style == .highlighted
                ? 2
                : 1
            for rect in documentLayout.selectionRects(
                forUTF16Range: lower..<upper,
                textSystem: uiContext.services.textSystem)
            {
                var underline = Path()
                let documentRect = offsetForInsets(rect)
                underline.addRect(Rect(
                    x: documentRect.origin.x,
                    y: documentRect.origin.y
                        + documentRect.size.height
                        - thickness,
                    width: documentRect.size.width,
                    height: thickness))
                context.fill(underline)
            }
        }
    }

    private func notifyInputMethodOfStateChange(
        cause: TextInputChangeCause = .other
    ) {
        window?.textInputContext.invalidateState(
            for: self,
            cause: cause)
    }

    // MARK: - TextInputClient

    public func insertText(_ string: String) {
        preeditStyles = []
        model.commitMarkedText(string)
        afterEdit(cause: .inputMethod)
    }

    public func setMarkedText(
        _ string: String,
        selectedRange: Range<Int>?
    ) {
        model.setMarkedText(string, selectedRange: selectedRange)
        afterEdit(cause: .inputMethod)
    }

    public func unmarkText() {
        preeditStyles = []
        model.unmarkText()
        afterEdit(cause: .inputMethod)
    }

    public func setMarkedTextStyles(
        _ styles: [TextInputPreeditSpan]
    ) {
        preeditStyles = styles
        textContentView.setNeedsDisplay()
    }

    public func textInputDidChangeLanguage(_ language: String?) {
        inputLanguage = language
    }

    public func performTextInputAction() {
        onSubmit?(self)
    }

    public var hasMarkedText: Bool {
        model.hasMarkedText
    }

    public var markedRange: Range<Int>? {
        model.markedRange
    }

    public var selectedRange: Range<Int> {
        model.selection.range
    }

    public func deleteSurroundingText(
        beforeBytes: Int,
        afterBytes: Int
    ) {
        model.deleteSurroundingText(
            beforeBytes: beforeBytes,
            afterBytes: afterBytes)
        afterEdit(cause: .inputMethod)
    }

    public func textInputSurroundingContext()
        -> TextInputSurroundingContext?
    {
        guard let context = model.surroundingText() else {
            return nil
        }
        return TextInputSurroundingContext(
            text: context.text,
            cursorByteOffset: context.cursor,
            anchorByteOffset: context.anchor)
    }

    public var textInputCaretRect: Rect {
        caretRect
    }

    public var textInputContentType: TextInputContentType {
        contentType
    }

    public var textInputHints: TextInputHints {
        hints.union(.multiline)
    }

    open override var accessibilityValue: String? {
        get { model.text }
        set {
            guard let newValue else { return }
            stringValue = newValue
        }
    }

    // MARK: - Shared editing command host

    package var editorModel: TextEditorModel {
        get { model }
        set { model = newValue }
    }

    package var editorAllowsMultilineText: Bool {
        true
    }

    package var editorIsFocused: Bool {
        isFocused
    }

    package var editorPasteboard: Pasteboard {
        uiContext.services.pasteboard
    }

    package var editorSceneIsConnected: Bool {
        window?.windowScene?.activationState != .disconnected
    }

    package func editorDidEdit(cause: TextInputChangeCause) {
        afterEdit(cause: cause)
    }

    package func editorDidChangeSelection() {
        afterSelectionChange(resetPreferredX: true)
    }

    package var accessibilityEditorText: String {
        get { stringValue }
        set { stringValue = newValue }
    }

    package var accessibilityEditorSelection: Range<Int> {
        selectedRange
    }

    package var accessibilityEditorIsSecure: Bool {
        false
    }

    package var accessibilityEditorIsMultiline: Bool {
        true
    }

    package func setAccessibilityEditorSelection(
        _ range: Range<Int>
    ) {
        setSelectedRange(range)
    }
}
