import Testing
import NucleusTextBackend
@_spi(NucleusCompositor) @testable import NucleusUI

@MainActor
@Suite(.uiContext, .serialized)
/// Release editor gate. Cache and paragraph bounds depend on viewport and
/// document structure, never machine speed.
struct NucleusTextEditorStressTests {
    private final class DelayedReadAdapter: PasteboardAdapter {
        private var continuation:
            CheckedContinuation<
                Result<String?, PasteboardFailure>,
                Never
            >?

        var hasPendingRead: Bool { continuation != nil }

        func readString() async throws(PasteboardFailure) -> String? {
            let result = await withCheckedContinuation {
                continuation = $0
            }
            return try result.get()
        }

        func writeString(
            _ string: String
        ) async throws(PasteboardFailure) {
            _ = string
        }

        func clear() async throws(PasteboardFailure) {}

        func complete(_ value: String?) {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: .success(value))
        }

        func shutdown() {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: .failure(.cancelled))
        }
    }

    init() {
        installTestTextBackend()
    }

    private func makeEditor(
        _ string: String,
        width: Double = 180,
        height: Double = 90
    ) -> (TextView, Window) {
        let editor = TextView(string: string)
        editor.frame = Rect(
            x: 0,
            y: 0,
            width: width,
            height: height)
        let window = Window(title: "Document")
        window.setContentView(editor)
        window.orderFront()
        editor.layoutIfNeeded()
        return (editor, window)
    }

    private func key(
        _ code: KeyCode,
        _ modifiers: EventModifierFlags = [],
        characters: String? = nil
    ) -> Event {
        Event(
            type: .keyDown,
            modifierFlags: modifiers,
            keyCode: code,
            characters: characters)
    }

    @Test
    func editorScrollsInsteadOfGrowingWithItsDocument() {
        let text = (0..<120)
            .map { "paragraph \($0)" }
            .joined(separator: "\n")
        let (editor, window) = makeEditor(text)
        #expect(window.makeFirstResponder(editor))
        editor.layoutIfNeeded()

        #expect(editor.intrinsicContentSize.height < editor.contentSize.height)
        #expect(editor.contentSize.height > editor.viewportSize.height)
        #expect(editor.contentOffset.y > 0)
        #expect(editor.caretRect.origin.y >= 0)
        #expect(editor.caretRect.origin.y < editor.bounds.size.height)
    }

    @Test
    func localEditPreservesParagraphIdentityAndUnchangedLayouts() {
        let (editor, _) = makeEditor("one\ntwo\nthree", height: 200)
        _ = editor.accessibilityRects(
            forUTF16Range: 0..<editor.stringValue.utf16.count)
        let originalIDs = editor.paragraphIDs
        let originalCreations = editor.paragraphLayoutCreationCount

        editor.stringValue = "one\ntwo!\nthree"
        _ = editor.accessibilityRects(
            forUTF16Range: 0..<editor.stringValue.utf16.count)

        #expect(editor.paragraphIDs == originalIDs)
        #expect(
            editor.paragraphLayoutCreationCount
                == originalCreations + 1)
    }

    @Test
    func viewportLayoutCacheStaysBoundedAcrossLongDocumentScrolling() {
        let text = (0..<2_000)
            .map { "line \($0)" }
            .joined(separator: "\n")
        let (editor, _) = makeEditor(text)

        let maximum = editor.scrollView.maximumOffset.y
        for step in 0...100 {
            editor.contentOffset = Point(
                x: 0,
                y: maximum * Double(step) / 100)
            editor.prepareVisibleParagraphLayouts()
            #expect(
                editor.cachedParagraphLayoutCount
                    <= TextDocumentLayoutStore.maximumCachedParagraphs)
        }

        #expect(editor.paragraphIDs.count == 2_000)
    }

    @Test
    func visualLineAndDocumentNavigationUseUTF16Offsets() {
        let (editor, window) = makeEditor("ab\n😀x\nlast")
        #expect(window.makeFirstResponder(editor))

        editor.setSelectedRange(5..<5)
        #expect(editor.handleEvent(key(.home)) == .handled)
        #expect(editor.selectedRange == 3..<3)
        #expect(editor.handleEvent(key(.end)) == .handled)
        #expect(editor.selectedRange == 6..<6)

        #expect(editor.handleEvent(key(
            .home,
            [.command])) == .handled)
        #expect(editor.selectedRange == 0..<0)
        #expect(editor.handleEvent(key(
            .end,
            [.command])) == .handled)
        let end = editor.stringValue.utf16.count
        #expect(editor.selectedRange == end..<end)

        editor.setSelectedRange(1..<1)
        #expect(editor.handleEvent(key(.downArrow)) == .handled)
        #expect(editor.selectedRange.lowerBound >= 3)
        #expect(editor.handleEvent(key(.upArrow)) == .handled)
        #expect(editor.selectedRange.lowerBound <= 2)
    }

    @Test
    func horizontalPolicyScrollsLongLinesAndWrapPolicyDoesNot() {
        let text = String(repeating: "abcdefghij", count: 40)
        let (editor, window) = makeEditor(text, width: 120)
        #expect(window.makeFirstResponder(editor))

        editor.lineLayout = .horizontal
        editor.layoutIfNeeded()
        editor.setSelectedRange(
            text.utf16.count..<text.utf16.count)
        #expect(editor.contentSize.width > editor.viewportSize.width)
        #expect(editor.contentOffset.x > 0)

        editor.lineLayout = .wrap
        editor.layoutIfNeeded()
        #expect(editor.contentOffset.x == 0)
        #expect(editor.contentSize.width == editor.viewportSize.width)
    }

    @Test
    func compositionUndoAndPasteShareTheFieldEditingContract()
        async
    {
        let (editor, window) = makeEditor("ab")
        #expect(window.makeFirstResponder(editor))

        editor.setMarkedText("にほん", selectedRange: nil)
        editor.insertText("日本")
        #expect(editor.stringValue == "ab日本")
        #expect(editor.handleEvent(key(
            .unknown,
            [.command],
            characters: "z")) == .handled)
        #expect(editor.stringValue == "ab")

        let pasteboard = Pasteboard(
            adapter: InMemoryPasteboardAdapter())
        try? await pasteboard.writeString("x\ny")
        #expect(await editor.paste(from: pasteboard))
        #expect(editor.stringValue == "abx\ny")
    }

    @Test
    func latePasteCannotMutateADetachedEditor() async {
        let adapter = DelayedReadAdapter()
        let pasteboard = Pasteboard(adapter: adapter)
        let root = View()
        let editor = TextView(string: "before")
        root.addSubview(editor)
        let window = Window()
        window.setContentView(root)
        window.orderFront()
        #expect(window.makeFirstResponder(editor))

        let operation = Task {
            await editor.paste(from: pasteboard)
        }
        await Task.yield()
        #expect(adapter.hasPendingRead)
        editor.removeFromSuperview()
        adapter.complete("late")

        #expect(!(await operation.value))
        #expect(editor.stringValue == "before")
    }

    @Test
    func accessibilityExportsOneStableMultilineEditableObject() throws {
        let (editor, window) = makeEditor("first\nsecond")
        let scene = WindowScene(inMemoryWindows: [window])
        let tree = AccessibilityTree(scene: scene)
        _ = tree.publish()
        let first = try #require(tree.snapshot.nodes[editor.accessibilityID])

        #expect(first.role == .textArea)
        #expect(first.state.contains(.editable))
        #expect(first.state.contains(.multiline))
        #expect(first.value == "first\nsecond")

        editor.setSelectedRange(6..<12)
        _ = tree.publish()
        let second = try #require(
            tree.snapshot.nodes[editor.accessibilityID])
        #expect(second.id == first.id)
        #expect(second.textSelection?.utf16Range == 6..<12)
        #expect(!editor.accessibilityRects(
            forUTF16Range: 6..<12).isEmpty)
    }

    @Test
    func widthScaleAndBackendChangesInvalidateParagraphLayouts() {
        let (editor, _) = makeEditor("one\ntwo\nthree", height: 200)
        _ = editor.accessibilityRects(
            forUTF16Range: 0..<editor.stringValue.utf16.count)
        let initial = editor.paragraphLayoutCreationCount

        editor.frame = Rect(
            x: 0,
            y: 0,
            width: 100,
            height: 200)
        editor.layoutIfNeeded()
        _ = editor.accessibilityRects(
            forUTF16Range: 0..<editor.stringValue.utf16.count)
        #expect(editor.paragraphLayoutCreationCount >= initial + 3)

        let afterWidth = editor.paragraphLayoutCreationCount
        editor.uiContext.updateEnvironment(
            editor.uiContext.environment.replacing(textScale: 1.25))
        _ = editor.accessibilityRects(
            forUTF16Range: 0..<editor.stringValue.utf16.count)
        #expect(
            editor.paragraphLayoutCreationCount
                >= afterWidth + 3)

        let afterScale = editor.paragraphLayoutCreationCount
        var paragraphStyle = editor.paragraphStyle
        paragraphStyle.lineSpacing = 3
        editor.paragraphStyle = paragraphStyle
        _ = editor.accessibilityRects(
            forUTF16Range: 0..<editor.stringValue.utf16.count)
        #expect(
            editor.paragraphLayoutCreationCount
                >= afterScale + 3)

        let afterParagraphStyle =
            editor.paragraphLayoutCreationCount
        SkiaTextLayoutBackend.install(in: editor.uiContext.services.textSystem)
        _ = editor.accessibilityRects(
            forUTF16Range: 0..<editor.stringValue.utf16.count)
        #expect(
            editor.paragraphLayoutCreationCount
                >= afterParagraphStyle + 3)
    }
}
