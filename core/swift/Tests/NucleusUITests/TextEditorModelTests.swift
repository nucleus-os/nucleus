import Testing
import NucleusUI

/// The editing contract, tested without a view or a window. The model is a
/// value type precisely so this is possible.
@MainActor
@Suite struct TextEditorModelTests {
    // MARK: - Index spaces

    /// UTF-16 is the model's index space and UTF-8 is the input method's. Text
    /// outside the BMP makes them disagree, which is exactly where naive
    /// conversion breaks.
    @Test func offsetsConvertBetweenUTF16AndUTF8() {
        // "a" + U+1F600 (2 UTF-16 units, 4 UTF-8 bytes) + "b"
        let model = TextEditorModel(text: "a😀b")
        #expect(model.utf16Count == 4)

        #expect(model.utf8Offset(forUTF16: 0) == 0)
        #expect(model.utf8Offset(forUTF16: 1) == 1)
        #expect(model.utf8Offset(forUTF16: 3) == 5, "past the 4-byte emoji")
        #expect(model.utf8Offset(forUTF16: 4) == 6)

        #expect(model.utf16Offset(forUTF8: 0) == 0)
        #expect(model.utf16Offset(forUTF8: 5) == 3)
        #expect(model.utf16Offset(forUTF8: 6) == 4)
    }

    /// A UTF-8 offset landing inside a multi-byte scalar has no UTF-16
    /// equivalent. Rounding down to the enclosing boundary is the only safe
    /// answer; inventing an offset would desynchronize the IME.
    @Test func aUTF8OffsetInsideAScalarRoundsDown() {
        let model = TextEditorModel(text: "a😀b")
        // Bytes 2, 3, 4 are continuation bytes of the emoji.
        #expect(model.utf16Offset(forUTF8: 3) == 1)
    }

    @Test func offsetsAreClampedRatherThanTrapping() {
        let model = TextEditorModel(text: "abc")
        #expect(model.utf8Offset(forUTF16: 99) == 3)
        #expect(model.utf16Offset(forUTF8: -5) == 0)
        #expect(model.alignedOffset(99) == 3)
    }

    // MARK: - Caret movement

    /// The caret moves by grapheme cluster, not code unit. A flag is one step.
    @Test func caretMovesByGraphemeClusterNotCodeUnit() {
        var model = TextEditorModel(text: "🇯🇵x")
        #expect(model.utf16Count == 5, "the flag is four UTF-16 units")

        model.setCaret(at: 0)
        model.moveCaret(.forward)
        #expect(model.selection.head == 4, "one step cleared the whole flag")
        model.moveCaret(.forward)
        #expect(model.selection.head == 5)
    }

    @Test func combiningSequencesMoveAsOneCaretStep() {
        var model = TextEditorModel(text: "e\u{0301}f")  // e + combining acute
        model.setCaret(at: 0)
        model.moveCaret(.forward)
        #expect(model.selection.head == 2, "the accent moved with its base")
    }

    @Test func movementStopsAtTheEnds() {
        var model = TextEditorModel(text: "ab")
        model.setCaret(at: 0)
        model.moveCaret(.backward)
        #expect(model.selection.head == 0)
        model.setCaret(at: 2)
        model.moveCaret(.forward)
        #expect(model.selection.head == 2)
    }

    @Test func wordMovementSkipsSeparatorsThenTheWord() {
        var model = TextEditorModel(text: "one two  three")
        model.setCaret(at: 0)
        model.moveCaret(.wordForward)
        #expect(model.selection.head == 3, "end of 'one'")
        model.moveCaret(.wordForward)
        #expect(model.selection.head == 7, "end of 'two'")

        model.setCaret(at: 14)
        model.moveCaret(.wordBackward)
        #expect(model.selection.head == 9, "start of 'three'")
        model.moveCaret(.wordBackward)
        #expect(model.selection.head == 4, "start of 'two'")
    }

    @Test func lineMovementGoesToTheEnds() {
        var model = TextEditorModel(text: "hello")
        model.setCaret(at: 2)
        model.moveCaret(.beginningOfLine)
        #expect(model.selection.head == 0)
        model.moveCaret(.endOfLine)
        #expect(model.selection.head == 5)
    }

    // MARK: - Selection

    @Test func extendingMovesTheHeadAndLeavesTheAnchor() {
        var model = TextEditorModel(text: "abcdef")
        model.setCaret(at: 2)
        model.moveCaret(.forward, extendingSelection: true)
        model.moveCaret(.forward, extendingSelection: true)

        #expect(model.selection.anchor == 2)
        #expect(model.selection.head == 4)
        #expect(model.selection.range == 2..<4)
        #expect(!model.selection.isCollapsed)
    }

    /// With a selection active, an unextended arrow collapses to the edge
    /// rather than moving one past it. AppKit behaviour, and the one people
    /// notice immediately when it is wrong.
    @Test func anUnextendedArrowCollapsesToTheSelectionEdge() {
        var model = TextEditorModel(text: "abcdef")
        model.setSelection(TextSelection(anchor: 1, head: 4))
        model.moveCaret(.forward)
        #expect(model.selection == TextSelection(caretAt: 4))

        model.setSelection(TextSelection(anchor: 1, head: 4))
        model.moveCaret(.backward)
        #expect(model.selection == TextSelection(caretAt: 1))
    }

    @Test func selectionIsOrderIndependent() {
        let backwards = TextSelection(anchor: 5, head: 2)
        #expect(backwards.range == 2..<5)
        #expect(backwards.lowerBound == 2)
        #expect(backwards.upperBound == 5)
    }

    @Test func selectAllCoversTheWholeText() {
        var model = TextEditorModel(text: "abc")
        model.selectAll()
        #expect(model.selection.range == 0..<3)
    }

    // MARK: - Editing

    @Test func insertingReplacesTheSelection() {
        var model = TextEditorModel(text: "hello world")
        model.setSelection(TextSelection(anchor: 6, head: 11))
        model.insert("there")

        #expect(model.text == "hello there")
        #expect(model.selection == TextSelection(caretAt: 11))
    }

    @Test func deleteBackwardRemovesAWholeGrapheme() {
        var model = TextEditorModel(text: "a🇯🇵")
        model.setCaret(at: model.utf16Count)
        model.deleteBackward()
        #expect(model.text == "a", "the flag went as one unit")
    }

    @Test func deleteForwardRemovesAheadOfTheCaret() {
        var model = TextEditorModel(text: "abc")
        model.setCaret(at: 1)
        model.deleteForward()
        #expect(model.text == "ac")
        #expect(model.selection == TextSelection(caretAt: 1))
    }

    @Test func deletingWithASelectionRemovesTheSelection() {
        var model = TextEditorModel(text: "abcdef")
        model.setSelection(TextSelection(anchor: 1, head: 4))
        model.deleteBackward()
        #expect(model.text == "aef")
        #expect(model.selection == TextSelection(caretAt: 1))
    }

    @Test func wordDeletionRemovesToTheWordBoundary() {
        var model = TextEditorModel(text: "one two three")
        model.setCaret(at: 13)
        model.deleteWordBackward()
        #expect(model.text == "one two ")

        model.setCaret(at: 0)
        model.deleteWordForward()
        #expect(model.text == " two ")
    }

    @Test func deletingAtABoundaryIsANoOp() {
        var model = TextEditorModel(text: "ab")
        model.setCaret(at: 0)
        model.deleteBackward()
        #expect(model.text == "ab")
        model.setCaret(at: 2)
        model.deleteForward()
        #expect(model.text == "ab")
    }

    @Test func maximumLengthRejectsAnOverlongInsertion() {
        var model = TextEditorModel(text: "abc")
        model.maximumLength = 5
        model.setCaret(at: 3)
        model.insert("de")
        #expect(model.text == "abcde")
        model.insert("f")
        #expect(model.text == "abcde", "rejected rather than truncated")
    }

    // MARK: - Composition

    @Test func markedTextIsProvisionalAndReplacedInPlace() {
        var model = TextEditorModel(text: "ab")
        model.setCaret(at: 2)

        model.setMarkedText("に")
        #expect(model.text == "abに")
        #expect(model.hasMarkedText)
        #expect(model.markedRange == 2..<3)

        // The next preedit replaces the previous one rather than appending.
        model.setMarkedText("にほん")
        #expect(model.text == "abにほん")
        #expect(model.markedRange == 2..<5)
    }

    @Test func aPreeditCanPlaceTheCaretInsideItself() {
        var model = TextEditorModel(text: "")
        model.setMarkedText("にほんご", selectedRange: 2..<2)
        #expect(model.selection == TextSelection(caretAt: 2))
    }

    @Test func unmarkingRemovesTheProvisionalText() {
        var model = TextEditorModel(text: "ab")
        model.setCaret(at: 2)
        model.setMarkedText("にほん")
        model.unmarkText()

        #expect(model.text == "ab")
        #expect(!model.hasMarkedText)
        #expect(model.selection == TextSelection(caretAt: 2))
    }

    @Test func committingReplacesTheCompositionWithFinalText() {
        var model = TextEditorModel(text: "ab")
        model.setCaret(at: 2)
        model.setMarkedText("にほん")
        model.commitMarkedText("日本")

        #expect(model.text == "ab日本")
        #expect(!model.hasMarkedText)
        #expect(model.selection == TextSelection(caretAt: 4))
    }

    @Test func anEmptyPreeditClearsTheComposition() {
        var model = TextEditorModel(text: "x")
        model.setCaret(at: 1)
        model.setMarkedText("あ")
        model.setMarkedText("")
        #expect(model.text == "x")
        #expect(!model.hasMarkedText)
    }

    /// A normal edit while composing drops the composition rather than leaving
    /// a stale marked range pointing into shifted text.
    @Test func editingClearsAStaleMarkedRange() {
        var model = TextEditorModel(text: "")
        model.setMarkedText("あ")
        model.insert("z")
        #expect(!model.hasMarkedText)
    }

    @Test func deleteSurroundingTextWorksInUTF8Bytes() {
        var model = TextEditorModel(text: "a😀bc")
        model.setCaret(at: model.utf16Count)  // after "c"
        // 1 byte after the caret's predecessor... delete "bc" (2 bytes) back.
        model.deleteSurroundingText(beforeBytes: 2, afterBytes: 0)
        #expect(model.text == "a😀")
    }

    @Test func surroundingTextReportsUTF8CursorOffsets() {
        var model = TextEditorModel(text: "a😀b")
        model.setSelection(TextSelection(anchor: 1, head: 3))
        let context = model.surroundingText()
        #expect(context?.text == "a😀b")
        #expect(context?.anchor == 1)
        #expect(context?.cursor == 5)
    }

    // MARK: - Secure entry

    /// The masking guarantees, together. A secure field must not leak through
    /// display, the clipboard, an input method, or a log line.
    @Test func aSecureFieldMasksItsDisplayText() {
        let model = TextEditorModel(text: "hunter2", isSecure: true)
        #expect(model.displayText == "•••••••")
        #expect(model.text == "hunter2", "the real text is still editable")
    }

    /// Masking is per grapheme, so a combining sequence does not leak its
    /// length as extra bullets.
    @Test func maskingCountsGraphemesNotCodeUnits() {
        let model = TextEditorModel(text: "e\u{0301}😀", isSecure: true)
        #expect(model.utf16Count == 4)
        #expect(model.displayText == "••", "two user-perceived characters")
    }

    @Test func aSecureFieldRefusesToBeCopied() {
        var model = TextEditorModel(text: "hunter2", isSecure: true)
        model.selectAll()
        #expect(!model.isCopyable)
        #expect(model.copyableSelection() == nil)
    }

    @Test func aSecureFieldReportsNoSurroundingTextToAnInputMethod() {
        var model = TextEditorModel(text: "hunter2", isSecure: true)
        model.setCaret(at: 7)
        #expect(model.surroundingText() == nil)
    }

    @Test func aSecureFieldRedactsItsDescription() {
        let model = TextEditorModel(text: "hunter2", isSecure: true)
        #expect(!model.description.contains("hunter2"))
        #expect(!"\(model)".contains("hunter2"))
    }

    @Test func anOrdinarySelectionIsCopyable() {
        var model = TextEditorModel(text: "hello")
        model.setSelection(TextSelection(anchor: 1, head: 4))
        #expect(model.copyableSelection() == "ell")
    }

    // MARK: - Undo

    /// Consecutive typing is one undo step, not one per keystroke.
    @Test func typingCoalescesIntoASingleUndoStep() {
        var model = TextEditorModel(text: "")
        model.insert("h")
        model.insert("i")
        model.insert("!")
        #expect(model.text == "hi!")

        let didUndo = model.undo()
        #expect(didUndo)
        #expect(model.text == "", "the whole run went at once")
    }

    /// But a change of kind closes the group, so typing and deleting are
    /// separately undoable.
    @Test func aDifferentKindOfEditStartsANewUndoStep() {
        var model = TextEditorModel(text: "")
        model.insert("abc")
        model.deleteBackward()
        #expect(model.text == "ab")

        let didUndoDeletion = model.undo()
        #expect(didUndoDeletion)
        #expect(model.text == "abc", "the deletion alone was undone")
        let didUndoTyping = model.undo()
        #expect(didUndoTyping)
        #expect(model.text == "")
    }

    /// Moving the caret ends the run: typing, clicking elsewhere, then typing
    /// again is two steps.
    @Test func movingTheCaretClosesTheUndoGroup() {
        var model = TextEditorModel(text: "xy")
        model.setCaret(at: 2)
        model.insert("a")
        model.setCaret(at: 0)
        model.insert("b")
        #expect(model.text == "bxya")

        let didUndo = model.undo()
        #expect(didUndo)
        #expect(model.text == "xya")
    }

    @Test func redoReappliesAnUndoneEdit() {
        var model = TextEditorModel(text: "")
        model.insert("hello")
        let didUndo = model.undo()
        #expect(didUndo)
        #expect(model.canRedo)
        let didRedo = model.redo()
        #expect(didRedo)
        #expect(model.text == "hello")
    }

    @Test func aNewEditClearsTheRedoStack() {
        var model = TextEditorModel(text: "")
        model.insert("hello")
        let didUndo = model.undo()
        #expect(didUndo)
        model.insert("x")
        #expect(!model.canRedo)
    }

    @Test func undoRestoresTheSelectionAlongWithTheText() {
        var model = TextEditorModel(text: "abcdef")
        model.setSelection(TextSelection(anchor: 1, head: 4))
        model.insert("Z")
        #expect(model.text == "aZef")

        let didUndo = model.undo()
        #expect(didUndo)
        #expect(model.text == "abcdef")
        #expect(model.selection == TextSelection(anchor: 1, head: 4))
    }

    @Test func undoAtTheBottomOfTheStackReportsFailure() {
        var model = TextEditorModel(text: "abc")
        #expect(!model.canUndo)
        let didUndo = model.undo()
        #expect(!didUndo)
    }

    /// A commit is undoable as one edit; the preedit churn before it is not
    /// separately undoable, which is what every platform does.
    @Test func aCommittedCompositionIsOneUndoStep() {
        var model = TextEditorModel(text: "")
        model.setMarkedText("に")
        model.setMarkedText("にほん")
        model.commitMarkedText("日本")
        #expect(model.text == "日本")

        let didUndo = model.undo()
        #expect(didUndo)
        #expect(model.text == "", "back past the whole composition")
    }
}
