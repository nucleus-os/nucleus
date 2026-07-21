import Testing
import NucleusUI

/// `TextField` behaviour: focus, keyboard editing, pointer selection, secure
/// entry, and the input-method client contract.
@MainActor
@Suite(.uiContext) struct TextFieldTests {
    private final class ControlledPasteboardAdapter: PasteboardAdapter {
        private var reads:
            [CheckedContinuation<Result<String?, PasteboardFailure>, Never>] = []
        private var writes:
            [CheckedContinuation<Result<Void, PasteboardFailure>, Never>] = []
        var delaysWrites = false
        var immediateWriteFailure: PasteboardFailure?
        private(set) var isShutdown = false

        var pendingReadCount: Int { reads.count }
        var pendingWriteCount: Int { writes.count }

        func readString() async throws(PasteboardFailure) -> String? {
            guard !isShutdown else { throw .unavailable }
            let result = await withCheckedContinuation { continuation in
                reads.append(continuation)
            }
            return try result.get()
        }

        func writeString(
            _ string: String
        ) async throws(PasteboardFailure) {
            _ = string
            guard !isShutdown else { throw .unavailable }
            if let immediateWriteFailure {
                throw immediateWriteFailure
            }
            guard delaysWrites else { return }
            let result: Result<Void, PasteboardFailure> =
                await withCheckedContinuation { continuation in
                    writes.append(continuation)
                }
            return try result.get()
        }

        func clear() async throws(PasteboardFailure) {
            guard !isShutdown else { throw .unavailable }
        }

        func completeNextRead(
            with result: Result<String?, PasteboardFailure>
        ) {
            reads.removeFirst().resume(returning: result)
        }

        func completeNextWrite(
            with result: Result<Void, PasteboardFailure>
        ) {
            writes.removeFirst().resume(returning: result)
        }

        func shutdown() {
            guard !isShutdown else { return }
            isShutdown = true
            let pendingReads = reads
            reads.removeAll()
            for continuation in pendingReads {
                continuation.resume(returning: .failure(.cancelled))
            }
            let pendingWrites = writes
            writes.removeAll()
            for continuation in pendingWrites {
                continuation.resume(returning: .failure(.cancelled))
            }
        }
    }

    init() {
        installTestTextBackend()
    }

    private func makeField(
        _ string: String = "", isSecure: Bool = false, width: Double = 200
    ) -> (TextField, Window) {
        let field = TextField(string: string, isSecure: isSecure)
        field.frame = Rect(x: 0, y: 0, width: width, height: 24)
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: width, height: 60)
        root.addSubview(field)
        let window = Window(title: "Field")
        window.setContentView(root)
        window.orderFront()
        return (field, window)
    }

    private func key(
        _ code: KeyCode, _ modifiers: EventModifierFlags = [], characters: String? = nil
    ) -> Event {
        Event(type: .keyDown, modifierFlags: modifiers, keyCode: code, characters: characters)
    }

    private func typing(_ text: String) -> Event {
        Event(type: .keyDown, keyCode: .unknown, characters: text)
    }

    // MARK: - Focus

    @Test func aFieldTakesFocusAndActivatesTheInputContext() {
        let (field, window) = makeField()
        #expect(field.acceptsFirstResponder)
        #expect(window.makeFirstResponder(field))
        #expect(field.isFocused)
        #expect(window.textInputContext.activeClient === field)
    }

    @Test func aDisabledFieldRefusesFocus() {
        let (field, window) = makeField()
        field.isEnabled = false
        #expect(!field.acceptsFirstResponder)
        #expect(!window.makeFirstResponder(field))
    }

    @Test func resigningFocusDeactivatesTheInputContext() {
        let (field, window) = makeField()
        #expect(window.makeFirstResponder(field))
        #expect(window.makeFirstResponder(nil))
        #expect(window.textInputContext.activeClient == nil)
        #expect(!field.isFocused)
    }

    /// Losing focus mid-composition must not leave provisional text the user
    /// never agreed to.
    @Test func losingFocusAbandonsAnOpenComposition() {
        let (field, window) = makeField("ab")
        #expect(window.makeFirstResponder(field))
        field.setMarkedText("にほん", selectedRange: nil)
        #expect(field.hasMarkedText)

        #expect(window.makeFirstResponder(nil))
        #expect(!field.hasMarkedText)
        #expect(field.stringValue == "ab", "the preedit went with it")
    }

    // MARK: - Keyboard editing

    @Test func typedCharactersAreInserted() {
        let (field, window) = makeField()
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(typing("h"))
        _ = field.handleEvent(typing("i"))
        #expect(field.stringValue == "hi")
    }

    /// Text comes from `characters` — what the platform's input method
    /// produced — never from the key code, which cannot account for layout.
    @Test func insertionUsesComposedCharactersNotTheKeyCode() {
        let (field, window) = makeField()
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(Event(type: .keyDown, keyCode: .unknown, characters: "é"))
        #expect(field.stringValue == "é")
    }

    @Test func backspaceDeletesBackward() {
        let (field, window) = makeField("abc")
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(key(.delete))
        #expect(field.stringValue == "ab")
    }

    @Test func arrowsMoveTheCaretAndShiftExtendsTheSelection() {
        let (field, window) = makeField("abcdef")
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(key(.leftArrow))
        _ = field.handleEvent(key(.leftArrow, .shift))
        #expect(field.selectedRange == 4..<5)
    }

    @Test func wordModifiersMoveAndDeleteByWord() {
        let (field, window) = makeField("one two three")
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(key(.leftArrow, .option))
        #expect(field.selectedRange == 8..<8, "start of 'three'")

        _ = field.handleEvent(key(.delete, .option))
        #expect(field.stringValue == "one three")
    }

    @Test func homeAndEndGoToTheTextBoundaries() {
        let (field, window) = makeField("abcdef")
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(key(.home))
        #expect(field.selectedRange == 0..<0)
        _ = field.handleEvent(key(.end))
        #expect(field.selectedRange == 6..<6)
    }

    @Test func returnSubmitsWithoutInsertingANewline() {
        let (field, window) = makeField("value")
        #expect(window.makeFirstResponder(field))
        var submitted = 0
        field.onSubmit = { _ in submitted += 1 }

        _ = field.handleEvent(key(.return, characters: "\n"))
        #expect(submitted == 1)
        #expect(field.stringValue == "value", "a single-line field takes no newline")
    }

    @Test func commandAselectsAllAndCommandZUndoes() {
        let (field, window) = makeField()
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(typing("hello"))

        _ = field.handleEvent(key(.unknown, .command, characters: "a"))
        #expect(field.selectedRange == 0..<5)

        _ = field.handleEvent(key(.unknown, .command, characters: "z"))
        #expect(field.stringValue == "")
    }

    @Test func commandEditingActionsTraverseTheResponderChain() {
        let (field, window) = makeField("hello")
        #expect(window.makeFirstResponder(field))
        field.clearAction(.copy)
        var routed = 0
        field.parentView?.setAction(.copy) { _ in routed += 1 }

        #expect(field.handleEvent(
            key(.unknown, .command, characters: "c")) == .handled)
        #expect(routed == 1)
    }

    @Test func onChangeFiresForEditsButNotForCaretMoves() {
        let (field, window) = makeField("ab")
        #expect(window.makeFirstResponder(field))
        var changes = 0
        field.onChange = { _ in changes += 1 }

        _ = field.handleEvent(typing("c"))
        #expect(changes == 1)
        _ = field.handleEvent(key(.leftArrow))
        #expect(changes == 1, "moving the caret is not a change")
    }

    @Test func aDisabledFieldIgnoresKeys() {
        let (field, window) = makeField("ab")
        #expect(window.makeFirstResponder(field))
        field.isEnabled = false
        _ = field.handleEvent(typing("c"))
        #expect(field.stringValue == "ab")
    }

    @Test func maximumLengthIsEnforcedThroughTheField() {
        let (field, window) = makeField("abc")
        field.maximumLength = 4
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(typing("d"))
        _ = field.handleEvent(typing("e"))
        #expect(field.stringValue == "abcd")
    }

    // MARK: - Pointer

    @Test func clickingPlacesTheCaretAndTakesFocus() {
        let (field, window) = makeField("hello world")
        // `View.parentWindow` is weak, so the window has to outlive the
        // assertions or the field has nothing to take focus in.
        withExtendedLifetime(window) {
            let event = Event(
                type: .pointerDown, location: Point(x: 30, y: 12), button: .left, clickCount: 1)
            #expect(field.handleEvent(event) == .handled)
            #expect(field.isFocused)
            #expect(field.selectedRange.isEmpty, "a click collapses to a caret")
        }
    }

    @Test func clickingPastTheEndPlacesTheCaretAtTheEnd() {
        let (field, _) = makeField("hi")
        let event = Event(
            type: .pointerDown, location: Point(x: 190, y: 12), button: .left, clickCount: 1)
        _ = field.handleEvent(event)
        #expect(field.selectedRange == 2..<2)
    }

    @Test func doubleClickSelectsAWord() {
        let (field, _) = makeField("one two three")
        let event = Event(
            type: .pointerDown, location: Point(x: 8, y: 12), button: .left, clickCount: 2)
        _ = field.handleEvent(event)
        #expect(field.selectedRange == 0..<3, "the word under the pointer")
    }

    @Test func tripleClickSelectsEverything() {
        let (field, _) = makeField("one two three")
        let event = Event(
            type: .pointerDown, location: Point(x: 8, y: 12), button: .left, clickCount: 3)
        _ = field.handleEvent(event)
        #expect(field.selectedRange == 0..<13)
    }

    @Test func draggingExtendsTheSelectionFromThePressPoint() {
        let (field, _) = makeField("one two three")
        _ = field.handleEvent(Event(
            type: .pointerDown, location: Point(x: 6, y: 12), button: .left, clickCount: 1))
        let anchor = field.selectedRange.lowerBound

        _ = field.handleEvent(Event(
            type: .pointerDragged, location: Point(x: 60, y: 12), button: .left))
        #expect(field.selectedRange.lowerBound == anchor)
        #expect(!field.selectedRange.isEmpty, "the drag selected something")
    }

    @Test func aSecondaryClickDoesNotMoveTheCaret() {
        let (field, window) = makeField("hello")
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(key(.home))
        let result = field.handleEvent(Event(
            type: .pointerDown, location: Point(x: 40, y: 12), button: .right, clickCount: 1))
        #expect(result == .notHandled)
        #expect(field.selectedRange == 0..<0)
    }

    // MARK: - Caret

    @Test func theCaretIsOnlyDrawnWhenFocusedAndCollapsed() {
        let (field, window) = makeField("abc")
        #expect(!field.isCaretVisible, "unfocused")

        #expect(window.makeFirstResponder(field))
        #expect(field.isCaretVisible)

        field.selectAllText()
        #expect(!field.isCaretVisible, "a range selection shows no caret")
    }

    @Test func theCaretBlinksOverTime() {
        let (field, window) = makeField("abc")
        #expect(window.makeFirstResponder(field))
        #expect(field.isCaretVisible)

        field.advanceCaretBlink(nowNs: 600_000_000)
        #expect(!field.isCaretVisible, "off in the second half-period")
        field.advanceCaretBlink(nowNs: 1_200_000_000)
        #expect(field.isCaretVisible, "and back on")
    }

    /// A caret that vanishes mid-keystroke reads as dropped input, so any edit
    /// restarts the blink solid.
    @Test func typingRestartsTheBlinkSolid() {
        let (field, window) = makeField("abc")
        #expect(window.makeFirstResponder(field))
        field.advanceCaretBlink(nowNs: 600_000_000)
        #expect(!field.isCaretVisible)

        _ = field.handleEvent(typing("d"))
        #expect(field.isCaretVisible)
    }

    /// The caret must stay on screen in a field whose text is wider than it is.
    @Test func aLongLineScrollsToKeepTheCaretVisible() {
        let (field, window) = makeField(String(repeating: "wide ", count: 40), width: 100)
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(key(.end))

        let caret = field.caretRect
        #expect(caret.origin.x >= 0)
        #expect(caret.origin.x <= 100, "the caret is inside the field, not off its right edge")
    }

    @Test func candidateGeometryCrossesViewWindowAndSurfaceExactlyOnce() {
        let (field, window) = makeField("candidate")
        field.frame = Rect(x: 15, y: 12, width: 180, height: 24)
        window.setFrame(Rect(x: 400, y: 250, width: 240, height: 80))
        let association = WindowSurfaceAssociation(
            surfaceID: PresentationSurfaceID(rawValue: 91),
            transform: WindowSurfaceTransform(
                windowOriginInSurface: Point(x: 7.5, y: 3.25),
                surfaceOriginInOutput: Point(x: 400, y: 250),
                backingScaleFactor: BackingScaleFactor(1.5)
            )
        )
        window.setSurfaceAssociation(association)

        let geometry = field.textInputCandidateGeometry
        let candidate = field.convert(field.caretRect, to: nil)
        let expected = association.transform.surfaceRect(fromWindow: candidate)

        #expect(geometry?.surfaceID == PresentationSurfaceID(rawValue: 91))
        #expect(geometry?.rect == expected)
        #expect(
            association.transform.surfaceRect(
                fromBacking: association.transform.backingRect(fromSurface: expected)
            ) == expected
        )
    }

    // MARK: - Secure entry

    @Test func aSecureFieldMasksWhatItDraws() {
        let (field, _) = makeField("hunter2", isSecure: true)
        #expect(field.stringValue == "hunter2")
        #expect(field.textLayout().text == "•••••••", "the laid-out text is masked")
    }

    @Test func aSecureFieldReportsNoAccessibilityValue() {
        let (field, _) = makeField("hunter2", isSecure: true)
        #expect(field.accessibilityValue == nil)

        let (ordinary, _) = makeField("visible")
        #expect(ordinary.accessibilityValue == "visible")
    }

    /// Every input-method surface a password could escape through, closed.
    @Test func aSecureFieldTellsTheInputMethodNothing() {
        let (field, window) = makeField("hunter2", isSecure: true)
        #expect(window.makeFirstResponder(field))

        #expect(field.textInputSurroundingContext() == nil)
        #expect(field.textInputContentType == .password)
        #expect(field.textInputHints == [.sensitiveData])
    }

    /// Content type cannot be configured out of secure treatment.
    @Test func secureEntryOverridesAConfiguredContentType() {
        let (field, _) = makeField("hunter2", isSecure: true)
        field.contentType = .email
        field.hints = [.spellcheck, .autocorrect]
        #expect(field.textInputContentType == .password)
        #expect(!field.textInputHints.contains(.spellcheck))
    }

    @Test func togglingSecureEntryMasksExistingText() {
        let (field, _) = makeField("hunter2")
        #expect(field.textLayout().text == "hunter2")
        field.isSecure = true
        #expect(field.textLayout().text == "•••••••")
    }

    @Test func standardPasteboardActionsRespectFocusAndSecureEntry() async throws {
        let adapter = InMemoryPasteboardAdapter()
        let pasteboard = Pasteboard(adapter: adapter)
        let (field, window) = makeField("copy me")
        field.setSelectedRange(0..<4)
        #expect(!(await field.copySelection(to: pasteboard)), "unfocused fields do not act")

        #expect(window.makeFirstResponder(field))
        #expect(await field.copySelection(to: pasteboard))
        #expect(try await pasteboard.readString() == "copy")

        field.isSecure = true
        field.selectAllText()
        #expect(!(await field.copySelection(to: pasteboard)))
        #expect(!(await field.cutSelection(to: pasteboard)))
        #expect(field.stringValue == "copy me")

        try await pasteboard.writeString("replacement")
        #expect(await field.paste(from: pasteboard))
        #expect(field.stringValue == "replacement")
    }

    @Test
    func latePasteIsDiscardedAfterTextMutation() async {
        let adapter = ControlledPasteboardAdapter()
        let pasteboard = Pasteboard(adapter: adapter)
        let (field, window) = makeField("original")
        #expect(window.makeFirstResponder(field))

        let paste = Task { await field.paste(from: pasteboard) }
        await Task.yield()
        #expect(adapter.pendingReadCount == 1)

        field.stringValue = "newer"
        adapter.completeNextRead(with: .success("stale"))

        #expect(!(await paste.value))
        #expect(field.stringValue == "newer")
    }

    @Test
    func lateCutDoesNotDeleteAChangedSelection() async {
        let adapter = ControlledPasteboardAdapter()
        adapter.delaysWrites = true
        let pasteboard = Pasteboard(adapter: adapter)
        let (field, window) = makeField("copy me")
        #expect(window.makeFirstResponder(field))
        field.setSelectedRange(0..<4)

        let cut = Task { await field.cutSelection(to: pasteboard) }
        await Task.yield()
        #expect(adapter.pendingWriteCount == 1)

        field.setSelectedRange(5..<7)
        adapter.completeNextWrite(with: .success(()))

        #expect(!(await cut.value))
        #expect(field.stringValue == "copy me")
        #expect(field.selectedRange == 5..<7)
    }

    @Test
    func failedCutLeavesTextAndSelectionUntouched() async {
        let adapter = ControlledPasteboardAdapter()
        adapter.immediateWriteFailure = .transport("rejected")
        let pasteboard = Pasteboard(adapter: adapter)
        let (field, window) = makeField("copy me")
        #expect(window.makeFirstResponder(field))
        field.setSelectedRange(0..<4)

        #expect(!(await field.cutSelection(to: pasteboard)))
        #expect(field.stringValue == "copy me")
        #expect(field.selectedRange == 0..<4)
    }

    @Test
    func latePasteIsDiscardedAfterFocusLoss() async {
        let adapter = ControlledPasteboardAdapter()
        let pasteboard = Pasteboard(adapter: adapter)
        let (field, window) = makeField("original")
        #expect(window.makeFirstResponder(field))

        let paste = Task { await field.paste(from: pasteboard) }
        await Task.yield()
        #expect(adapter.pendingReadCount == 1)
        #expect(window.makeFirstResponder(nil))
        adapter.completeNextRead(with: .success("stale"))

        #expect(!(await paste.value))
        #expect(field.stringValue == "original")
    }

    @Test func textViewAcceptsNewlinesAndUsesMultilineInputHints() {
        let view = TextView(string: "first")
        view.frame = Rect(x: 0, y: 0, width: 120, height: 80)
        let window = Window(title: "Editor")
        window.setContentView(view)
        window.orderFront()
        #expect(window.makeFirstResponder(view))

        #expect(view.handleEvent(key(.return)) == .handled)
        #expect(view.stringValue == "first\n")
        #expect(view.textInputHints.contains(.multiline))
        view.layoutIfNeeded()
        #expect(view.scrollView.documentView != nil)
        #expect(view.scrollView.superview === view)
    }

    // MARK: - Input method

    @Test func aPreeditIsProvisionalAndCommitsAsFinalText() {
        let (field, window) = makeField("ab")
        #expect(window.makeFirstResponder(field))

        field.setMarkedText("にほん", selectedRange: nil)
        #expect(field.stringValue == "abにほん")
        #expect(field.hasMarkedText)
        #expect(field.markedRange == 2..<5)

        field.insertText("日本")
        #expect(field.stringValue == "ab日本")
        #expect(!field.hasMarkedText)
    }

    @Test func theFieldReportsSurroundingTextInUTF8Offsets() {
        let (field, window) = makeField("a😀b")
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(key(.end))

        let context = field.textInputSurroundingContext()
        #expect(context?.text == "a😀b")
        #expect(context?.cursorByteOffset == 6)
    }

    @Test func theInputMethodCanDeleteSurroundingText() {
        let (field, window) = makeField("abcd")
        #expect(window.makeFirstResponder(field))
        _ = field.handleEvent(key(.end))

        field.deleteSurroundingText(beforeBytes: 2, afterBytes: 0)
        #expect(field.stringValue == "ab")
    }

    /// A state change notifies the adapter so the input method's cached view
    /// does not go stale.
    @Test func editsNotifyTheInputMethodAdapter() {
        final class RecordingAdapter: TextInputAdapter {
            var activations = 0
            var deactivations = 0
            var stateChanges = 0
            func textInputDidActivate(_ client: any TextInputClient) { activations += 1 }
            func textInputDidDeactivate(_ client: any TextInputClient) { deactivations += 1 }
            func textInputDidChangeState(
                _ client: any TextInputClient,
                cause: TextInputChangeCause
            ) {
                stateChanges += 1
            }
        }

        let (field, window) = makeField("ab")
        let adapter = RecordingAdapter()
        window.installTextInputAdapter(adapter)

        #expect(window.makeFirstResponder(field))
        #expect(adapter.activations == 1)

        _ = field.handleEvent(typing("c"))
        #expect(adapter.stateChanges >= 1)

        #expect(window.makeFirstResponder(nil))
        #expect(adapter.deactivations == 1)
    }

    @Test func escapeAbandonsACompositionAndIsOtherwiseUnhandled() {
        let (field, window) = makeField("ab")
        #expect(window.makeFirstResponder(field))
        #expect(field.handleEvent(key(.escape)) == .notHandled, "free to close a sheet")

        field.setMarkedText("にほん", selectedRange: nil)
        #expect(field.handleEvent(key(.escape)) == .handled)
        #expect(field.stringValue == "ab")
    }
}
