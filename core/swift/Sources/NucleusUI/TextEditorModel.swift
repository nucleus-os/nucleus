/// A caret or range within text, in UTF-16 offsets.
///
/// UTF-16 is the canonical index space because that is what the text substrate
/// speaks: `TextLayoutLine.sourceUTF16Range`, `glyphPosition(at:)`, and
/// `selectionRects(forUTF16Range:)` all use it. Input methods speak UTF-8
/// instead, so the model converts at that boundary rather than carrying two
/// index spaces internally.
///
/// `anchor` is where the selection was started and `head` is where it is being
/// dragged to, so `head` is the end that moves and the end the caret is drawn
/// at. A collapsed selection is a caret.
public struct TextSelection: Equatable, Sendable {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    /// A collapsed selection at `offset`.
    public init(caretAt offset: Int) {
        self.init(anchor: offset, head: offset)
    }

    public var range: Range<Int> {
        min(anchor, head)..<max(anchor, head)
    }

    public var isCollapsed: Bool { anchor == head }
    public var lowerBound: Int { min(anchor, head) }
    public var upperBound: Int { max(anchor, head) }
}

/// How a caret moves in response to a navigation command.
public enum TextMovement: Sendable, Equatable {
    /// One grapheme cluster, not one UTF-16 unit — a flag emoji moves as one
    /// caret step, not four.
    case backward
    case forward
    case wordBackward
    case wordForward
    case beginningOfLine
    case endOfLine
}

/// The editing model behind `TextField`: text, selection, composition, and undo.
///
/// A value type with no view, layout, or platform dependency, so the whole
/// editing contract is testable without a window. `TextField` owns one and
/// renders it; an input method drives it through the same public API a keystroke
/// does.
public struct TextEditorModel: Equatable, Sendable {
    /// The real text, always — masking is a presentation concern and applies to
    /// `displayText`, never to what is stored or edited.
    public private(set) var text: String
    public private(set) var selection: TextSelection

    /// The uncommitted composition region, if an input method is mid-composition.
    /// Marked text is *in* `text` — that is what lets it lay out and draw in
    /// place — but it is provisional and gets replaced wholesale on the next
    /// preedit update or commit.
    public private(set) var markedRange: Range<Int>?

    /// Caret affinity at a soft line wrap, where one offset has two valid
    /// on-screen positions: end of the wrapped line or start of the next.
    public var affinity: TextAffinity

    /// Masks `displayText` and suppresses every path that would let the contents
    /// escape — see `isCopyable`, `accessibilityValue`, and `description`.
    public var isSecure: Bool

    /// Rejects insertions that would take the text past this many UTF-16 units.
    /// `nil` means unlimited.
    public var maximumLength: Int?

    private var undoStack: [UndoEntry]
    private var redoStack: [UndoEntry]
    /// Consecutive typing coalesces into one undo step. This records what the
    /// open group is doing so an unrelated edit can close it.
    private var openGroup: UndoGroupKind?
    /// Whether the pre-composition state has already been pushed for the open
    /// composition. Preedit churn must not each become its own undo step, but
    /// the *whole* composition must be undoable back past where it started.
    private var compositionUndoRecorded: Bool

    private struct UndoEntry: Equatable, Sendable {
        var text: String
        var selection: TextSelection
    }

    private enum UndoGroupKind: Equatable, Sendable {
        case typing
        case deleting
    }

    public init(text: String = "", isSecure: Bool = false) {
        self.text = text
        self.selection = TextSelection(caretAt: text.utf16.count)
        self.markedRange = nil
        self.affinity = .downstream
        self.isSecure = isSecure
        self.maximumLength = nil
        self.undoStack = []
        self.redoStack = []
        self.openGroup = nil
        self.compositionUndoRecorded = false
    }

    // MARK: - Offsets

    public var utf16Count: Int { text.utf16.count }
    public var isEmpty: Bool { text.isEmpty }

    /// What a viewer should see. Secure fields mask by *grapheme*, so one
    /// bullet per user-perceived character rather than per code unit — a
    /// combining sequence must not leak its length.
    public var displayText: String {
        isSecure ? String(repeating: "•", count: text.count) : text
    }

    /// UTF-8 byte offset for a UTF-16 offset. Input-method protocols
    /// (`zwp_text_input_v3` among them) index surrounding text in UTF-8 bytes.
    public func utf8Offset(forUTF16 offset: Int) -> Int {
        guard let index = index(atUTF16: offset) else { return text.utf8.count }
        return text.utf8.distance(from: text.utf8.startIndex, to: index)
    }

    public func utf16Offset(forUTF8 offset: Int) -> Int {
        let clamped = min(max(0, offset), text.utf8.count)
        guard let index = text.utf8.index(
            text.utf8.startIndex, offsetBy: clamped, limitedBy: text.utf8.endIndex)
        else { return utf16Count }
        // A UTF-8 offset landing mid-scalar has no UTF-16 equivalent; round down
        // to the enclosing scalar boundary rather than inventing one.
        let scalarAligned = index.samePosition(in: text.unicodeScalars)
            ?? text.unicodeScalars.index(before: text.unicodeScalars.index(after: index))
        return text.utf16.distance(from: text.utf16.startIndex, to: scalarAligned)
    }

    private func index(atUTF16 offset: Int) -> String.Index? {
        let clamped = min(max(0, offset), utf16Count)
        guard let index = text.utf16.index(
            text.utf16.startIndex, offsetBy: clamped, limitedBy: text.utf16.endIndex)
        else { return nil }
        // Offsets from a layout can land between surrogates; snap to a real
        // String.Index rather than trapping.
        return index.samePosition(in: text) ?? text.index(before: index)
    }

    private func range(forUTF16 range: Range<Int>) -> Range<String.Index> {
        let lower = index(atUTF16: range.lowerBound) ?? text.startIndex
        let upper = index(atUTF16: range.upperBound) ?? text.endIndex
        return lower..<max(lower, upper)
    }

    /// Snap an arbitrary offset to the nearest grapheme boundary at or before
    /// it, so no API can leave the caret inside a cluster.
    public func alignedOffset(_ offset: Int) -> Int {
        let clamped = min(max(0, offset), utf16Count)
        guard let index = index(atUTF16: clamped) else { return utf16Count }
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    // MARK: - Selection

    public mutating func setSelection(_ selection: TextSelection) {
        self.selection = TextSelection(
            anchor: alignedOffset(selection.anchor), head: alignedOffset(selection.head))
        closeUndoGroup()
    }

    public mutating func setCaret(at offset: Int) {
        setSelection(TextSelection(caretAt: offset))
    }

    public mutating func selectAll() {
        setSelection(TextSelection(anchor: 0, head: utf16Count))
    }

    /// Move the caret, or extend the selection by moving only its head.
    public mutating func moveCaret(_ movement: TextMovement, extendingSelection: Bool = false) {
        // Collapsing to an edge is a move in its own right: with a selection
        // active, an unextended left/right arrow lands on the edge rather than
        // one step past it. Matches AppKit.
        if !extendingSelection, !selection.isCollapsed,
           movement == .backward || movement == .forward {
            setCaret(at: movement == .backward ? selection.lowerBound : selection.upperBound)
            return
        }

        let target = offset(after: movement, from: selection.head)
        if extendingSelection {
            setSelection(TextSelection(anchor: selection.anchor, head: target))
        } else {
            setCaret(at: target)
        }
    }

    private func offset(after movement: TextMovement, from origin: Int) -> Int {
        switch movement {
        case .beginningOfLine: return 0
        case .endOfLine: return utf16Count
        case .backward: return previousGrapheme(from: origin)
        case .forward: return nextGrapheme(from: origin)
        case .wordBackward: return previousWord(from: origin)
        case .wordForward: return nextWord(from: origin)
        }
    }

    private func previousGrapheme(from origin: Int) -> Int {
        guard let index = index(atUTF16: origin), index > text.startIndex else { return 0 }
        return text.utf16.distance(from: text.utf16.startIndex, to: text.index(before: index))
    }

    private func nextGrapheme(from origin: Int) -> Int {
        guard let index = index(atUTF16: origin), index < text.endIndex else { return utf16Count }
        return text.utf16.distance(from: text.utf16.startIndex, to: text.index(after: index))
    }

    /// Word movement skips any run of separators, then the word itself — so
    /// pressing it repeatedly walks word starts going backward and word ends
    /// going forward, as every text system does.
    private func previousWord(from origin: Int) -> Int {
        var index = index(atUTF16: origin) ?? text.endIndex
        while index > text.startIndex,
              isWordSeparator(text[text.index(before: index)]) {
            index = text.index(before: index)
        }
        while index > text.startIndex,
              !isWordSeparator(text[text.index(before: index)]) {
            index = text.index(before: index)
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    private func nextWord(from origin: Int) -> Int {
        var index = index(atUTF16: origin) ?? text.endIndex
        while index < text.endIndex, isWordSeparator(text[index]) {
            index = text.index(after: index)
        }
        while index < text.endIndex, !isWordSeparator(text[index]) {
            index = text.index(after: index)
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    private func isWordSeparator(_ character: Character) -> Bool {
        !(character.isLetter || character.isNumber || character == "_")
    }

    // MARK: - Editing

    /// Insert `string` at the caret, replacing any selection. Committing an
    /// input method's composition goes through here too.
    public mutating func insert(_ string: String) {
        guard !string.isEmpty else { return }
        openUndoGroup(.typing)
        replaceWithoutUndoGrouping(range: selection.range, with: string)
    }

    public mutating func deleteBackward() {
        openUndoGroup(.deleting)
        if selection.isCollapsed {
            let start = previousGrapheme(from: selection.head)
            guard start < selection.head else { return }
            replaceWithoutUndoGrouping(range: start..<selection.head, with: "")
        } else {
            replaceWithoutUndoGrouping(range: selection.range, with: "")
        }
    }

    public mutating func deleteForward() {
        openUndoGroup(.deleting)
        if selection.isCollapsed {
            let end = nextGrapheme(from: selection.head)
            guard end > selection.head else { return }
            replaceWithoutUndoGrouping(range: selection.head..<end, with: "")
        } else {
            replaceWithoutUndoGrouping(range: selection.range, with: "")
        }
    }

    public mutating func deleteWordBackward() {
        openUndoGroup(.deleting)
        guard selection.isCollapsed else {
            replaceWithoutUndoGrouping(range: selection.range, with: "")
            return
        }
        let start = previousWord(from: selection.head)
        guard start < selection.head else { return }
        replaceWithoutUndoGrouping(range: start..<selection.head, with: "")
    }

    public mutating func deleteWordForward() {
        openUndoGroup(.deleting)
        guard selection.isCollapsed else {
            replaceWithoutUndoGrouping(range: selection.range, with: "")
            return
        }
        let end = nextWord(from: selection.head)
        guard end > selection.head else { return }
        replaceWithoutUndoGrouping(range: selection.head..<end, with: "")
    }

    /// Replace an explicit range. Closes any open undo group, because a
    /// programmatic replacement is not a continuation of the user's typing.
    public mutating func replace(range: Range<Int>, with string: String) {
        closeUndoGroup()
        recordUndo()
        replaceWithoutUndoGrouping(range: range, with: string)
    }

    private mutating func replaceWithoutUndoGrouping(range: Range<Int>, with string: String) {
        let aligned = alignedOffset(range.lowerBound)..<alignedOffset(range.upperBound)
        let removed = aligned.upperBound - aligned.lowerBound
        if let maximumLength {
            let resulting = utf16Count - removed + string.utf16.count
            guard resulting <= maximumLength else { return }
        }
        text.replaceSubrange(self.range(forUTF16: aligned), with: string)
        let caret = aligned.lowerBound + string.utf16.count
        selection = TextSelection(caretAt: caret)
        markedRange = nil
        redoStack.removeAll()
    }

    // MARK: - Composition

    /// Install or update an input method's provisional text.
    ///
    /// The preedit replaces the previous preedit if one is open, otherwise the
    /// current selection. `selectedRange` is relative to `string` and positions
    /// the caret inside the composition — an IME showing "にほん|ご" needs that.
    public mutating func setMarkedText(_ string: String, selectedRange: Range<Int>? = nil) {
        closeUndoGroup()
        if markedRange == nil {
            // The composition is beginning. Capture the state before any
            // provisional text lands, so undoing after the commit goes back past
            // the whole composition rather than to a half-typed preedit.
            recordUndo()
            compositionUndoRecorded = true
        }
        let replacing = markedRange ?? selection.range
        let aligned = alignedOffset(replacing.lowerBound)..<alignedOffset(replacing.upperBound)
        text.replaceSubrange(range(forUTF16: aligned), with: string)

        if string.isEmpty {
            markedRange = nil
            selection = TextSelection(caretAt: aligned.lowerBound)
            return
        }
        markedRange = aligned.lowerBound..<(aligned.lowerBound + string.utf16.count)
        if let selectedRange {
            let base = aligned.lowerBound
            selection = TextSelection(
                anchor: base + selectedRange.lowerBound, head: base + selectedRange.upperBound)
        } else {
            selection = TextSelection(caretAt: aligned.lowerBound + string.utf16.count)
        }
    }

    /// Abandon the composition, removing its provisional text.
    public mutating func unmarkText() {
        guard let markedRange else { return }
        text.replaceSubrange(range(forUTF16: markedRange), with: "")
        selection = TextSelection(caretAt: markedRange.lowerBound)
        self.markedRange = nil
        // The text is back where the composition found it, so the entry pushed
        // at composition start would undo to an identical state.
        if compositionUndoRecorded {
            undoStack.removeLast()
            compositionUndoRecorded = false
        }
    }

    /// Accept `string` as the final result of the composition. The committed
    /// text is a normal edit and therefore undoable, unlike the preedit updates
    /// that preceded it.
    public mutating func commitMarkedText(_ string: String) {
        let target = markedRange ?? selection.range
        closeUndoGroup()
        if !compositionUndoRecorded {
            // A commit with no composition open (a direct commit from an input
            // method) still needs its own undo step.
            recordUndo()
        }
        compositionUndoRecorded = false
        markedRange = nil
        replaceWithoutUndoGrouping(range: target, with: string)
    }

    public var hasMarkedText: Bool { markedRange != nil }

    /// Delete text around the caret at an input method's request, in UTF-8
    /// bytes before and after — `zwp_text_input_v3.delete_surrounding_text`.
    public mutating func deleteSurroundingText(beforeBytes: Int, afterBytes: Int) {
        let caretUTF8 = utf8Offset(forUTF16: selection.lowerBound)
        let endUTF8 = utf8Offset(forUTF16: selection.upperBound)
        let start = utf16Offset(forUTF8: max(0, caretUTF8 - max(0, beforeBytes)))
        let end = utf16Offset(forUTF8: endUTF8 + max(0, afterBytes))
        replace(range: start..<end, with: "")
    }

    /// Context an input method needs to compose sensibly: the text around the
    /// caret plus the caret and anchor as UTF-8 offsets into *that* string.
    ///
    /// Secure fields report nothing. A password must not reach an input method,
    /// which may log, learn from, or display it as a candidate.
    public func surroundingText(maximumBytes: Int = 4000) -> (text: String, cursor: Int, anchor: Int)? {
        guard !isSecure else { return nil }
        guard text.utf8.count <= maximumBytes else {
            // Oversized content is reported as empty rather than truncated at an
            // arbitrary point, which would desynchronize the IME's offsets.
            return ("", 0, 0)
        }
        return (
            text,
            utf8Offset(forUTF16: selection.head),
            utf8Offset(forUTF16: selection.anchor))
    }

    // MARK: - Undo

    /// Whether the contents may be placed on the clipboard. A secure field's
    /// never may.
    public var isCopyable: Bool { !isSecure }

    /// The selected text, or `nil` for a secure field or an empty selection.
    public func copyableSelection() -> String? {
        guard isCopyable, !selection.isCollapsed else { return nil }
        return String(text[range(forUTF16: selection.range)])
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        redoStack.append(UndoEntry(text: text, selection: selection))
        text = entry.text
        selection = entry.selection
        markedRange = nil
        openGroup = nil
        compositionUndoRecorded = false
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        undoStack.append(UndoEntry(text: text, selection: selection))
        text = entry.text
        selection = entry.selection
        markedRange = nil
        openGroup = nil
        compositionUndoRecorded = false
        return true
    }

    /// Take the contents as a scrubable buffer and clear the model.
    ///
    /// The exit path for a credential: after this the byte copy is the
    /// authoritative one and the model holds nothing. Undo history goes too,
    /// since it would otherwise still hold what was typed.
    ///
    /// The model's `String` storage is overwritten in place first. That is
    /// best-effort and deliberately not claimed as more: if the buffer was
    /// uniquely referenced the bytes really are overwritten, but Swift may have
    /// copied the string anywhere, and small strings live inline in the struct.
    /// The guarantee lives in `SecureBytes`, not here.
    public mutating func takeSecureBytes() -> SecureBytes {
        let bytes = SecureBytes(utf8: text)
        secureEraseStorage()
        discardUndoHistory()
        selection = TextSelection(caretAt: 0)
        markedRange = nil
        return bytes
    }

    /// Overwrite the text storage in place, then empty it.
    private mutating func secureEraseStorage() {
        guard !text.isEmpty else { return }
        // Same length, so a uniquely-referenced buffer is overwritten rather
        // than reallocated.
        text.replaceSubrange(text.startIndex..<text.endIndex,
                             with: String(repeating: "\u{0}", count: text.count))
        text = ""
    }

    /// Drop the undo and redo history outright.
    ///
    /// Clearing a secure field's text is not enough on its own: the previous
    /// contents stay recoverable through undo, which on a lock screen means a
    /// credential sitting in a buffer after it was supposedly cleared.
    public mutating func discardUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        openGroup = nil
        compositionUndoRecorded = false
    }

    /// End the current coalescing run, so the next edit starts a fresh undo
    /// step. Called on caret moves and by a field losing focus.
    public mutating func closeUndoGroup() {
        openGroup = nil
    }

    /// Begin an edit of kind `kind`, recording an undo entry only if this is not
    /// a continuation of the same kind of edit. Typing a word produces one undo
    /// step; typing then deleting produces two.
    private mutating func openUndoGroup(_ kind: UndoGroupKind) {
        guard openGroup != kind else { return }
        recordUndo()
        openGroup = kind
    }

    private mutating func recordUndo() {
        undoStack.append(UndoEntry(text: text, selection: selection))
        redoStack.removeAll()
    }
}

extension TextEditorModel: CustomStringConvertible {
    /// Redacted for secure fields. A password must not reach a log through an
    /// incidental interpolation of the model.
    public var description: String {
        isSecure
            ? "TextEditorModel(secure, \(text.count) characters)"
            : "TextEditorModel(\"\(text)\", selection: \(selection.range))"
    }
}
