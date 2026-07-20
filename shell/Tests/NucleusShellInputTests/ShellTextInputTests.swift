import Testing
import NucleusUI
@testable import NucleusShellInput

/// The `zwp_text_input_v3` mapping. The protocol object itself needs a live
/// compositor, so these cover the parts that are pure translation — content
/// type, hints, and preedit cursor offsets — plus the secure-entry guarantees
/// that must hold at this boundary.
@MainActor
@Suite(.uiContext) struct ShellTextInputTests {
    // MARK: - Content type

    @Test func contentTypesMapOntoProtocolPurposes() {
        // Values from the protocol's own enumeration.
        #expect(ShellTextInput.contentPurpose(.normal) == 0)
        #expect(ShellTextInput.contentPurpose(.number) == 3)
        #expect(ShellTextInput.contentPurpose(.phone) == 4)
        #expect(ShellTextInput.contentPurpose(.url) == 5)
        #expect(ShellTextInput.contentPurpose(.email) == 6)
        #expect(ShellTextInput.contentPurpose(.name) == 7)
        #expect(ShellTextInput.contentPurpose(.password) == 8)
        #expect(ShellTextInput.contentPurpose(.pin) == 9)
    }

    @Test func hintsMapOntoProtocolFlags() {
        #expect(ShellTextInput.contentHint([]) == 0)

        let spellcheck = ShellTextInput.contentHint([.spellcheck])
        #expect(spellcheck & 0x2 != 0)

        let multiline = ShellTextInput.contentHint([.multiline])
        #expect(multiline & 0x200 != 0)
    }

    /// A sensitive field must set both flags: `sensitive_data` asks the input
    /// method not to learn from or log the content, `hidden_text` that it not
    /// display it. Either one alone leaves a leak.
    @Test func sensitiveDataSetsBothProtectionFlags() {
        let hint = ShellTextInput.contentHint([.sensitiveData])
        #expect(hint & 0x80 != 0, "sensitive_data")
        #expect(hint & 0x40 != 0, "hidden_text")
    }

    /// The whole chain from a secure field to the wire: a secure `TextField`
    /// reports `.password` and only `.sensitiveData`, which becomes a purpose
    /// and hint pair that tells the input method to protect the content.
    @Test func aSecureFieldReachesTheWireAsAProtectedPassword() {
        let field = TextField(string: "hunter2", isSecure: true)
        field.contentType = .email  // deliberately wrong; secure must win

        #expect(ShellTextInput.contentPurpose(field.textInputContentType) == 8)
        let hint = ShellTextInput.contentHint(field.textInputHints)
        #expect(hint & 0x80 != 0)
        #expect(hint & 0x40 != 0)
        #expect(hint & 0x2 == 0, "no spellcheck on a password")
    }

    /// And it sends no surrounding text at all, rather than an empty string —
    /// which would still tell the input method the caret moved.
    @Test func aSecureFieldOffersNoSurroundingText() {
        let field = TextField(string: "hunter2", isSecure: true)
        #expect(field.textInputSurroundingContext() == nil)
    }

    // MARK: - Preedit cursor

    /// The protocol gives the preedit cursor in UTF-8 bytes into the preedit
    /// string; the framework indexes UTF-16. Text outside the BMP is where a
    /// naive pass-through breaks.
    @Test func preeditCursorConvertsFromUTF8Bytes() {
        // "a" + 4-byte emoji + "b"
        let text = "a😀b"
        #expect(ShellTextInput.utf16Offset(in: text, forUTF8: 0) == 0)
        #expect(ShellTextInput.utf16Offset(in: text, forUTF8: 1) == 1)
        #expect(ShellTextInput.utf16Offset(in: text, forUTF8: 5) == 3)
        #expect(ShellTextInput.utf16Offset(in: text, forUTF8: 6) == 4)
    }

    @Test func aPreeditSelectionSpansTheGivenRange() throws {
        let range = try #require(ShellTextInput.preeditSelection("にほんご", begin: 3, end: 6))
        #expect(range == 1..<2, "one character in, one character wide")
    }

    /// A negative cursor pair means "hide the cursor"; the field should not be
    /// handed a bogus range.
    @Test func aHiddenPreeditCursorYieldsNoSelection() {
        #expect(ShellTextInput.preeditSelection("にほん", begin: -1, end: -1) == nil)
    }

    @Test func aReversedPreeditCursorIsNormalized() throws {
        let range = try #require(ShellTextInput.preeditSelection("abcd", begin: 3, end: 1))
        #expect(range == 1..<3)
    }

    @Test func anOutOfRangePreeditCursorClampsToTheEnd() {
        #expect(ShellTextInput.utf16Offset(in: "ab", forUTF8: 99) == 2)
    }

    // MARK: - The client contract the protocol drives

    /// The protocol's commit/preedit sequence drives the field through
    /// `TextInputClient`, the same API a keystroke uses — there is no second
    /// editing path for composed text.
    @Test func theProtocolSequenceDrivesTheFieldThroughTheClientSeam() {
        let field = TextField(string: "ab")
        field.setSelectedRange(2..<2)

        // preedit → commit, as an input method composing "日本" would send.
        field.setMarkedText("にほん", selectedRange: 3..<3)
        #expect(field.stringValue == "abにほん")
        #expect(field.hasMarkedText)

        field.insertText("日本")
        #expect(field.stringValue == "ab日本")
        #expect(!field.hasMarkedText)
    }

    /// `delete_surrounding_text` is applied before the commit string, because
    /// its byte offsets were computed against the pre-delete text.
    @Test func deleteSurroundingAppliesBeforeTheCommit() {
        let field = TextField(string: "abcd")
        field.setSelectedRange(4..<4)

        field.deleteSurroundingText(beforeBytes: 2, afterBytes: 0)
        field.insertText("XY")
        #expect(field.stringValue == "abXY")
    }
}
