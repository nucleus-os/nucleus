/// A single-line editable text control.
///
/// Owns a `TextEditorModel` and renders it. Every editing operation goes through
/// the model, so a keystroke, a paste, and an input method's commit all take the
/// same path — there is no second editing implementation for composed text.
@MainActor
open class TextField:
    Control,
    TextInputClient,
    TextEditingCommandHost,
    RetainedTextEditorAccessibility,
    ~Sendable
{
    /// The edited text in cleartext, even when `isSecure` is true.
    ///
    /// Setting it replaces the contents and collapses the caret to the end, as
    /// `NSTextField.stringValue` does. Credential consumers should prefer
    /// `takeSecureCredential()` so the value leaves as scrubable storage rather
    /// than another Swift `String` copy.
    public var stringValue: String {
        get { model.text }
        set {
            guard newValue != model.text else { return }
            model = makeModel(text: newValue)
            editingCommands.advanceGeneration()
            invalidateTextLayout()
            notifyInputMethodOfStateChange()
            recordMutation(.accessibility)
            onChange?(self)
        }
    }

    /// Shown when the field is empty and unfocused.
    public var placeholderString: String = "" {
        didSet { if placeholderString != oldValue { invalidateTextLayout() } }
    }

    /// Obscures the contents and closes every path that would let them escape.
    /// Setting it rebuilds the model so the flag cannot disagree with the text
    /// already in it.
    public var isSecure: Bool {
        get { model.isSecure }
        set {
            guard newValue != model.isSecure else { return }
            model.setSecure(newValue)
            editingCommands.cancelAndAdvance()
            preeditStyles = []
            invalidateTextLayout()
            notifyInputMethodOfStateChange()
            recordMutation(.accessibility)
        }
    }

    public var maximumLength: Int? {
        get { model.maximumLength }
        set { model.maximumLength = newValue }
    }

    public var font: Font = .systemFont(ofSize: 13) {
        didSet { if font != oldValue { invalidateTextLayout() } }
    }
    public var textColor: Color = Color(1, 1, 1, 1) {
        didSet { if textColor != oldValue { invalidateTextLayout() } }
    }
    public var placeholderColor: Color = Color(1, 1, 1, 0.4) {
        didSet { if placeholderColor != oldValue { invalidateTextLayout() } }
    }
    public var selectionColor: Color = Color(0.24, 0.51, 0.92, 0.55) {
        didSet { if selectionColor != oldValue { setNeedsDisplay() } }
    }
    public var caretColor: Color = Color(1, 1, 1, 1) {
        didSet { if caretColor != oldValue { setNeedsDisplay() } }
    }
    /// Space between the field's edges and its text.
    public var textInsets: EdgeInsets = EdgeInsets(top: 4, left: 6, bottom: 4, right: 6) {
        didSet { if textInsets != oldValue { invalidateTextLayout() } }
    }

    public var contentType: TextInputContentType = .normal
    public var hints: TextInputHints = [.spellcheck, .autocorrect]

    /// Subclasses such as `TextView` opt into wrapping and newline insertion.
    open var allowsMultilineText: Bool { false }

    /// Called after any change to the text.
    public var onChange: ((TextField) -> Void)?
    /// Called when Return is pressed.
    public var onSubmit: ((TextField) -> Void)?

    package var model: TextEditorModel

    /// Horizontal scroll offset in points. A single-line field reveals the caret
    /// by sliding its text rather than wrapping.
    package private(set) var scrollOffset: Double = 0

    private var cachedLayout: TextLayout?
    private var caretPhaseStartNs: UInt64 = 0
    private var caretVisibleOverride: Bool?
    private var preeditStyles: [TextInputPreeditSpan] = []
    public private(set) var inputLanguage: String?
    /// Where a drag-selection began, so dragging extends from the press point.
    private var selectionDragAnchor: Int?
    private lazy var editingCommands =
        TextEditingCommandCoordinator(host: self)

    public init(string: String = "", isSecure: Bool = false) {
        model = TextEditorModel(text: string, isSecure: isSecure)
        super.init()
        model.setCaret(at: model.utf16Count)
        accessibilityRole = .textField
        isEnabled = true
        editingCommands.installStandardActions(on: self)
    }

    private func makeModel(text: String) -> TextEditorModel {
        var replacement = TextEditorModel(text: text, isSecure: model.isSecure)
        replacement.maximumLength = model.maximumLength
        return replacement
    }

    // MARK: - Focus

    open override var acceptsFirstResponder: Bool { isEnabled }

    open override var environmentDependencies: UIEnvironmentChanges {
        super.environmentDependencies.union(.textScale)
    }

    open override func environmentDidChange(
        _ changes: UIEnvironmentChanges
    ) {
        if changes.contains(.textScale) {
            invalidateTextLayout()
        }
        super.environmentDidChange(changes)
    }

    open override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        editingCommands.advanceGeneration()
        window?.textInputContext.activate(self)
        restartCaretBlink()
        setNeedsDisplay()
        return true
    }

    open override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        editingCommands.cancelAndAdvance()
        // An abandoned composition must not leave provisional text behind that
        // the user never agreed to.
        if model.hasMarkedText { model.unmarkText() }
        model.closeUndoGroup()
        window?.textInputContext.deactivate(self)
        setNeedsDisplay()
        return true
    }

    // MARK: - Selection

    public func selectAllText() {
        model.selectAll()
        afterSelectionChange()
    }

    public func copySelection() async -> Bool {
        await copySelection(to: uiContext.services.pasteboard)
    }

    public func copySelection(to pasteboard: Pasteboard) async -> Bool {
        await editingCommands.copy(to: pasteboard)
    }

    public func cutSelection() async -> Bool {
        await cutSelection(to: uiContext.services.pasteboard)
    }

    public func cutSelection(to pasteboard: Pasteboard) async -> Bool {
        await editingCommands.cut(to: pasteboard)
    }

    public func paste() async -> Bool {
        await paste(from: uiContext.services.pasteboard)
    }

    public func paste(from pasteboard: Pasteboard) async -> Bool {
        await editingCommands.paste(from: pasteboard)
    }

    open override func retainedHierarchyWillDetach() {
        editingCommands.cancelAndAdvance()
        super.retainedHierarchyWillDetach()
    }

    /// Drop the undo and redo history. Clearing a secure field's text leaves the
    /// previous contents recoverable through undo without this.
    public func discardUndoHistory() {
        model.discardUndoHistory()
    }

    /// Take the field's contents as a scrubable buffer and empty the field.
    ///
    /// How a credential leaves a secure field. The value never becomes a
    /// `String` that outlives the call, which a `stringValue` read would.
    public func takeSecureCredential() -> SecureBytes {
        let bytes = model.takeSecureBytes()
        editingCommands.advanceGeneration()
        invalidateTextLayout()
        notifyInputMethodOfStateChange()
        onChange?(self)
        return bytes
    }

    public func setSelectedRange(_ range: Range<Int>) {
        model.setSelection(TextSelection(anchor: range.lowerBound, head: range.upperBound))
        afterSelectionChange()
    }

    // MARK: - Caret blink

    /// Whether the caret is currently drawn. Off entirely when unfocused.
    public var isCaretVisible: Bool {
        guard isFocused, model.selection.isCollapsed else { return false }
        return caretVisibleOverride ?? true
    }

    /// Advance the blink to `nowNs`. Driven by the host's frame clock rather
    /// than an internal timer, matching how the stack view's transitions work —
    /// nothing in NucleusUI owns a clock.
    public func advanceCaretBlink(nowNs: UInt64) {
        guard isFocused else { return }
        let elapsed = nowNs &- caretPhaseStartNs
        let phase = (elapsed / TextField.caretBlinkIntervalNs) % 2
        let visible = phase == 0
        if visible != caretVisibleOverride {
            caretVisibleOverride = visible
            setNeedsDisplay()
        }
    }

    /// Restart the blink so the caret is solid immediately after it moves —
    /// a caret that vanishes mid-keystroke reads as dropped input.
    private func restartCaretBlink() {
        caretPhaseStartNs = 0
        caretVisibleOverride = true
    }

    private static let caretBlinkIntervalNs: UInt64 = 530_000_000

    // MARK: - Layout and measurement

    open override var intrinsicContentSize: Size {
        let layout = textLayout()
        return Size(
            width: max(80, layout.intrinsicSize.width + textInsets.left + textInsets.right),
            height: max(22, layout.intrinsicSize.height + textInsets.top + textInsets.bottom))
    }

    open override func measure(_ constraints: LayoutConstraints) -> Size {
        constraints.constrain(intrinsicContentSize)
    }

    private var textRect: Rect {
        Rect(
            x: textInsets.left, y: textInsets.top,
            width: max(0, bounds.size.width - textInsets.left - textInsets.right),
            height: max(0, bounds.size.height - textInsets.top - textInsets.bottom))
    }

    /// The laid-out text as displayed — masked for a secure field, so no
    /// measurement or hit test can recover the real characters' widths.
    package func textLayout() -> TextLayout {
        if let cachedLayout { return cachedLayout }
        let string = model.displayText
        let layout = TextLayout(
            runs: [TextRun(
                text: string,
                font: font.scaled(by: uiContext.environment.textScale),
                color: textColor)],
            containerWidth: allowsMultilineText && textRect.size.width > 0
                ? textRect.size.width : nil,
            alignment: .leading,
            lineBreakMode: allowsMultilineText ? .byWordWrapping : .byClipping,
            numberOfLines: allowsMultilineText ? 0 : 1,
            textSystem: uiContext.services.textSystem)
        cachedLayout = layout
        return layout
    }

    private func invalidateTextLayout() {
        cachedLayout = nil
        invalidateIntrinsicContentSize()
        revealCaret()
        setNeedsDisplay()
    }

    /// Slide the text horizontally so the caret stays inside the visible area.
    private func revealCaret() {
        guard !allowsMultilineText else {
            scrollOffset = 0
            return
        }
        let visibleWidth = textRect.size.width
        guard visibleWidth > 0 else { return }
        let caretX = xPosition(forUTF16: model.selection.head)
        let layoutWidth = textLayout().intrinsicSize.width

        if caretX - scrollOffset < 0 {
            scrollOffset = caretX
        } else if caretX - scrollOffset > visibleWidth {
            scrollOffset = caretX - visibleWidth
        }
        // Never scroll past the text, and never scroll at all when it fits.
        scrollOffset = min(scrollOffset, max(0, layoutWidth - visibleWidth))
        scrollOffset = max(0, scrollOffset)
    }

    /// Horizontal position of a UTF-16 offset within the laid-out text.
    private func xPosition(forUTF16 offset: Int) -> Double {
        let layout = textLayout()
        if let caret = layout.caretGeometry(
            atUTF16Offset: offset,
            affinity: model.affinity,
            in: uiContext.services.textSystem
        ) {
            return caret.rect.origin.x
        }
        guard offset > 0 else { return 0 }
        let rects = layout.selectionRects(
            forUTF16Range: 0..<offset,
            in: uiContext.services.textSystem)
        guard let last = rects.last else {
            return layout.intrinsicSize.width
        }
        return last.rect.origin.x + last.rect.size.width
    }

    /// The offset nearest a point in this view's coordinates.
    package func offset(at point: Point) -> Int {
        let layout = textLayout()
        let local = Point(
            x: point.x - textRect.origin.x + scrollOffset,
            y: min(max(0, point.y - textRect.origin.y), max(0, layout.intrinsicSize.height - 1)))
        if local.x <= 0 { return 0 }
        if local.x >= layout.intrinsicSize.width { return model.utf16Count }
        guard let position = layout.glyphPosition(
            at: local,
            in: uiContext.services.textSystem
        ) else { return model.utf16Count }
        return model.alignedOffset(position.utf16Offset)
    }

    /// The caret's rectangle in this view's coordinates. Also what the input
    /// method uses to place candidate UI.
    public var caretRect: Rect {
        let layout = textLayout()
        if let caret = layout.caretGeometry(
            atUTF16Offset: model.selection.head,
            affinity: model.affinity,
            in: uiContext.services.textSystem
        ) {
            return Rect(
                x: textRect.origin.x + caret.rect.origin.x - scrollOffset,
                y: textRect.origin.y + caret.rect.origin.y,
                width: max(1, caret.rect.size.width),
                height: max(1, caret.rect.size.height)
            )
        }
        let height = layout.intrinsicSize.height > 0
            ? layout.intrinsicSize.height : Double(font.pointSize)
        return Rect(
            x: textRect.origin.x + xPosition(forUTF16: model.selection.head) - scrollOffset,
            y: textRect.origin.y,
            width: 1,
            height: height)
    }

    // MARK: - Drawing

    open override func draw(in context: GraphicsContext) {
        let layout = textLayout()
        let origin = Point(x: textRect.origin.x - scrollOffset, y: textRect.origin.y)

        context.saveGState()
        // Clip so text scrolled out of view does not paint over the border.
        var clip = Path()
        clip.addRect(textRect)
        context.clip(to: clip)

        if !model.selection.isCollapsed {
            context.fillColor = selectionColor
            for selectionRect in layout.selectionRects(
                forUTF16Range: model.selection.range,
                in: uiContext.services.textSystem
            ) {
                var path = Path()
                path.addRect(Rect(
                    x: origin.x + selectionRect.rect.origin.x,
                    y: origin.y + selectionRect.rect.origin.y,
                    width: selectionRect.rect.size.width,
                    height: selectionRect.rect.size.height))
                context.fill(path)
            }
        }

        if model.isEmpty, !placeholderString.isEmpty, !isFocused {
            let placeholder = TextLayout(
                runs: [TextRun(
                    text: placeholderString,
                    font: font.scaled(
                        by: uiContext.environment.textScale),
                    color: placeholderColor)],
                containerWidth: nil, alignment: .leading,
                lineBreakMode: .byTruncatingTail, numberOfLines: 1,
                textSystem: uiContext.services.textSystem)
            context.fillColor = placeholderColor
            context.draw(placeholder, in: Rect(
                origin: Point(x: textRect.origin.x, y: origin.y),
                size: placeholder.usedRect.size))
        } else if !layout.isEmpty {
            context.fillColor = textColor
            context.draw(layout, in: Rect(origin: origin, size: layout.usedRect.size))
        }

        // A composition is underlined so provisional text is visibly distinct
        // from committed text.
        if let markedRange = model.markedRange {
            let spans = preeditStyles.isEmpty
                ? [TextInputPreeditSpan(
                    range: 0..<markedRange.count,
                    style: .active
                )]
                : preeditStyles
            for span in spans {
                let lower = markedRange.lowerBound
                    + min(max(0, span.range.lowerBound), markedRange.count)
                let upper = markedRange.lowerBound
                    + min(max(0, span.range.upperBound), markedRange.count)
                guard lower < upper else { continue }
                context.fillColor = span.style == .incorrect
                    ? Color(0.95, 0.25, 0.25, 0.9)
                    : textColor.opacity(span.style == .inactive ? 0.45 : 0.7)
                let thickness: Double = span.style == .selected
                    || span.style == .highlighted ? 2 : 1
                for rect in layout.selectionRects(
                    forUTF16Range: lower..<upper,
                    in: uiContext.services.textSystem
                ) {
                    var underline = Path()
                    underline.addRect(Rect(
                        x: origin.x + rect.rect.origin.x,
                        y: origin.y + rect.rect.origin.y
                            + rect.rect.size.height - thickness,
                        width: rect.rect.size.width,
                        height: thickness
                    ))
                    context.fill(underline)
                }
            }
        }

        if isCaretVisible {
            context.fillColor = caretColor
            var caret = Path()
            caret.addRect(caretRect)
            context.fill(caret)
        }

        context.restoreGState()
    }

    // MARK: - Events

    open override func handleEvent(_ event: Event) -> EventHandling {
        guard isEnabled else { return .notHandled }
        switch event.type {
        case .pointerDown:
            return handlePointerDown(event)
        case .pointerDragged:
            guard let anchor = selectionDragAnchor else { return .notHandled }
            model.setSelection(TextSelection(anchor: anchor, head: offset(at: event.location)))
            afterSelectionChange()
            return .handled
        case .pointerUp:
            selectionDragAnchor = nil
            return .handled
        case .keyDown:
            return handleKeyDown(event)
        default:
            return super.handleEvent(event)
        }
    }

    private func handlePointerDown(_ event: Event) -> EventHandling {
        guard event.button == .left else { return .notHandled }
        if !isFocused {
            _ = window?.makeFirstResponder(self)
        }
        let offset = offset(at: event.location)
        switch event.clickCount {
        case 2:
            selectWord(containing: offset)
        case let count where count >= 3:
            model.selectAll()
        default:
            if event.modifierFlags.contains(.shift) {
                // Shift-click extends from the existing anchor rather than
                // starting a new selection.
                model.setSelection(TextSelection(anchor: model.selection.anchor, head: offset))
            } else {
                model.setCaret(at: offset)
            }
            selectionDragAnchor = model.selection.anchor
        }
        afterSelectionChange()
        return .handled
    }

    private func selectWord(containing offset: Int) {
        var probe = model
        probe.setCaret(at: offset)
        probe.moveCaret(.wordForward)
        let end = probe.selection.head
        probe.moveCaret(.wordBackward)
        model.setSelection(TextSelection(anchor: probe.selection.head, head: end))
    }

    private func handleKeyDown(_ event: Event) -> EventHandling {
        // A word-granularity modifier: Option on Apple keyboards, Control
        // elsewhere. Both are accepted rather than picking a side.
        let byWord = event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.control)
        let extending = event.modifierFlags.contains(.shift)
        let toLineBoundary = event.modifierFlags.contains(.command)

        switch event.keyCode {
        case .leftArrow:
            let movement: TextMovement = toLineBoundary ? .beginningOfLine
                : (byWord ? .wordBackward : .backward)
            model.moveCaret(movement, extendingSelection: extending)
            afterSelectionChange()
            return .handled
        case .rightArrow:
            let movement: TextMovement = toLineBoundary ? .endOfLine
                : (byWord ? .wordForward : .forward)
            model.moveCaret(movement, extendingSelection: extending)
            afterSelectionChange()
            return .handled
        case .home:
            model.moveCaret(.beginningOfLine, extendingSelection: extending)
            afterSelectionChange()
            return .handled
        case .end:
            model.moveCaret(.endOfLine, extendingSelection: extending)
            afterSelectionChange()
            return .handled
        case .delete:
            if byWord { model.deleteWordBackward() } else { model.deleteBackward() }
            afterEdit()
            return .handled
        case .forwardDelete:
            if byWord { model.deleteWordForward() } else { model.deleteForward() }
            afterEdit()
            return .handled
        case .return:
            if allowsMultilineText {
                model.insert("\n")
                afterEdit()
            } else {
                onSubmit?(self)
            }
            return .handled
        case .escape:
            if model.hasMarkedText {
                model.unmarkText()
                afterEdit()
                return .handled
            }
            return .notHandled
        default:
            break
        }

        if toLineBoundary, let characters = event.characters?.lowercased() {
            let action: ActionID? = switch characters {
            case "a": .selectAll
            case "c": .copy
            case "x": .cut
            case "v": .paste
            case "z": event.modifierFlags.contains(.shift) ? .redo : .undo
            default: nil
            }
            guard let action else { return .notHandled }
            return performAction(action, event: event)
                ? .handled
                : .notHandled
        }

        // Composed text last: `characters` is what the platform's input method
        // produced, never something derived from the key code.
        if let characters = event.characters, !characters.isEmpty {
            model.insert(characters)
            afterEdit()
            return .handled
        }
        return .notHandled
    }

    private func afterEdit(cause: TextInputChangeCause = .other) {
        editingCommands.advanceGeneration()
        invalidateTextLayout()
        restartCaretBlink()
        notifyInputMethodOfStateChange(cause: cause)
        recordMutation(.accessibility)
        onChange?(self)
    }

    private func afterSelectionChange() {
        editingCommands.advanceGeneration()
        revealCaret()
        restartCaretBlink()
        notifyInputMethodOfStateChange()
        recordMutation(.accessibility)
        setNeedsDisplay()
    }

    private func notifyInputMethodOfStateChange(
        cause: TextInputChangeCause = .other
    ) {
        window?.textInputContext.invalidateState(for: self, cause: cause)
    }

    // MARK: - Accessibility

    /// A secure field reports no value. An assistive technology reading the
    /// contents aloud is exactly the leak `isSecure` exists to prevent.
    open override var accessibilityValue: String? {
        get { model.isSecure ? nil : model.text }
        set { _ = newValue }
    }

    // MARK: - TextInputClient

    public func insertText(_ string: String) {
        preeditStyles = []
        model.commitMarkedText(string)
        afterEdit(cause: .inputMethod)
    }

    public func setMarkedText(_ string: String, selectedRange: Range<Int>?) {
        model.setMarkedText(string, selectedRange: selectedRange)
        afterEdit(cause: .inputMethod)
    }

    public func unmarkText() {
        preeditStyles = []
        model.unmarkText()
        afterEdit(cause: .inputMethod)
    }

    public func setMarkedTextStyles(_ styles: [TextInputPreeditSpan]) {
        preeditStyles = styles
        setNeedsDisplay()
    }

    public func textInputDidChangeLanguage(_ language: String?) {
        inputLanguage = language
    }

    public func performTextInputAction() {
        onSubmit?(self)
    }

    public var hasMarkedText: Bool { model.hasMarkedText }
    public var markedRange: Range<Int>? { model.markedRange }
    public var selectedRange: Range<Int> { model.selection.range }

    public func deleteSurroundingText(beforeBytes: Int, afterBytes: Int) {
        model.deleteSurroundingText(beforeBytes: beforeBytes, afterBytes: afterBytes)
        afterEdit(cause: .inputMethod)
    }

    public func textInputSurroundingContext() -> TextInputSurroundingContext? {
        guard let context = model.surroundingText() else { return nil }
        return TextInputSurroundingContext(
            text: context.text,
            cursorByteOffset: context.cursor,
            anchorByteOffset: context.anchor)
    }

    public var textInputCaretRect: Rect { caretRect }

    /// A secure field reports `.password` regardless of what was configured, so
    /// no adapter can be told to treat it as ordinary text.
    public var textInputContentType: TextInputContentType {
        model.isSecure ? .password : contentType
    }

    public var textInputHints: TextInputHints {
        guard model.isSecure else {
            return allowsMultilineText ? hints.union(.multiline) : hints
        }
        // Secure entry overrides every learning-related hint.
        return [.sensitiveData]
    }

    // MARK: - Shared editing command host

    package var editorModel: TextEditorModel {
        get { model }
        set { model = newValue }
    }

    package var editorAllowsMultilineText: Bool {
        allowsMultilineText
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
        afterSelectionChange()
    }

    package var accessibilityEditorText: String {
        get { stringValue }
        set { stringValue = newValue }
    }

    package var accessibilityEditorSelection: Range<Int> {
        selectedRange
    }

    package var accessibilityEditorIsSecure: Bool {
        isSecure
    }

    package var accessibilityEditorIsMultiline: Bool {
        false
    }

    package func setAccessibilityEditorSelection(
        _ range: Range<Int>
    ) {
        setSelectedRange(range)
    }
}
