import Testing
@testable import NucleusConfigSyntax

@Suite struct ConfigSyntaxTests {
    private func prepared(_ text: String) throws -> String {
        let bytes = try ConfigSyntax.prepare(ConfigSource(text: text))
        return String(decoding: bytes, as: UTF8.self)
    }

    private func failure(_ text: String) -> ConfigSyntaxError? {
        do {
            _ = try ConfigSyntax.prepare(ConfigSource(text: text))
            return nil
        } catch { return error }
    }

    // MARK: comment stripping

    @Test func stripsLineCommentsWithoutMovingAnyByte() throws {
        let text = "{\n  \"tap\": true // enable\n}"
        let output = try prepared(text)
        #expect(output == "{\n  \"tap\": true          \n}")
        #expect(output.utf8.count == text.utf8.count)
    }

    @Test func stripsBlockCommentsAndPreservesInteriorNewlines() throws {
        let text = "{\n/* one\n   two */\n\"tap\": true}"
        let output = try prepared(text)
        // Newlines survive so every line number after the comment is unchanged.
        // "/* one" is 6 bytes; "   two */" is 9.
        let blanked = "{\n" + String(repeating: " ", count: 6) + "\n"
            + String(repeating: " ", count: 9) + "\n\"tap\": true}"
        #expect(output == blanked)
        #expect(output.utf8.count == text.utf8.count)
    }

    @Test func leavesCommentMarkersInsideStringsAlone() throws {
        let text = #"{"path": "https://example.com/*x*/"}"#
        #expect(try prepared(text) == text)
    }

    @Test func leavesSourceWithoutCommentsByteIdentical() throws {
        let text = #"{"a":[1,2,{"b":"c"}],"d":true}"#
        #expect(try prepared(text) == text)
    }

    @Test func handlesEscapedQuotesWhenScanningStrings() throws {
        let text = #"{"quote": "a \" b // not a comment"}"#
        #expect(try prepared(text) == text)
    }

    @Test func stripsACommentThatEndsTheSourceWithoutNewline() throws {
        let text = "{\"a\":1} // trailing"
        // The space before "//" is source, not comment, so it survives as
        // itself; the 11 comment bytes become 11 spaces.
        let blanked = "{\"a\":1} " + String(repeating: " ", count: 11)
        #expect(try prepared(text) == blanked)
        #expect(blanked.utf8.count == text.utf8.count)
    }

    // MARK: structural diagnostics

    @Test func reportsUnclosedBraceAtItsOpeningLocation() throws {
        let error = try #require(failure("{\n  \"a\": {\n    \"b\": 1\n  }\n"))
        #expect(error.kind == .unclosedDelimiter(
            opener: UInt8(ascii: "{"),
            openedAt: SourceLocation(offset: 0, line: 1, column: 1)))
        #expect(error.primaryLocation.line == 1)
        #expect(error.primaryLocation.column == 1)
    }

    @Test func reportsMismatchedDelimiterAgainstBothEnds() throws {
        let error = try #require(failure("{\n  \"a\": [1, 2}\n}"))
        guard case .mismatchedDelimiter(let found, let expected, let openedAt)
            = error.kind
        else {
            Issue.record("expected a mismatched delimiter, got \(error.kind)")
            return
        }
        #expect(found == UInt8(ascii: "}"))
        #expect(expected == UInt8(ascii: "]"))
        #expect(openedAt.line == 2)
        #expect(openedAt.column == 8)
        #expect(error.location.line == 2)
        #expect(error.location.column == 13)
    }

    @Test func reportsAStrayCloserWhereItAppears() throws {
        let error = try #require(failure("{\"a\": 1}}"))
        #expect(error.kind == .unmatchedDelimiter(found: UInt8(ascii: "}")))
        #expect(error.location.column == 9)
    }

    @Test func reportsAForgottenClosingQuoteAtTheOpeningQuote() throws {
        // The newline is what proves the string was never closed. Pointing at
        // the opening quote sends the user to the typo, not to end of file.
        let error = try #require(failure("{\n  \"name\": \"unclosed\n}"))
        #expect(error.kind == .unterminatedString)
        #expect(error.location.line == 2)
        // Line 2 is `  "name": "unclosed`; the unclosed literal opens at
        // column 11, not at the earlier, properly closed `"name"`.
        #expect(error.location.column == 11)
    }

    @Test func reportsAnUnterminatedBlockComment() throws {
        let error = try #require(failure("{\n/* forever\n\"a\": 1}"))
        #expect(error.kind == .unterminatedBlockComment)
        #expect(error.location.line == 2)
        #expect(error.location.column == 1)
    }

    // MARK: location mapping

    @Test func mapsOffsetsToLineAndColumnAcrossLines() {
        let source = ConfigSource(text: "ab\ncde\n\nf")
        #expect(source.location(at: 0) == SourceLocation(offset: 0, line: 1, column: 1))
        #expect(source.location(at: 2) == SourceLocation(offset: 2, line: 1, column: 3))
        #expect(source.location(at: 3) == SourceLocation(offset: 3, line: 2, column: 1))
        #expect(source.location(at: 5) == SourceLocation(offset: 5, line: 2, column: 3))
        #expect(source.location(at: 7) == SourceLocation(offset: 7, line: 3, column: 1))
        #expect(source.location(at: 8) == SourceLocation(offset: 8, line: 4, column: 1))
    }

    @Test func clampsOffsetsPastTheEndSoEndOfInputStillResolves() {
        let source = ConfigSource(text: "ab\ncd")
        #expect(source.location(at: 999).line == 2)
        #expect(source.location(at: 999).offset == 5)
    }

    @Test func returnsLineTextWithoutItsTerminator() {
        let source = ConfigSource(text: "first\r\nsecond\nthird")
        #expect(source.line(1) == "first")
        #expect(source.line(2) == "second")
        #expect(source.line(3) == "third")
        #expect(source.line(4) == "")
    }

    @Test func countsColumnsInBytesForMultibyteText() {
        // Column is documented as a byte count; a two-byte scalar advances it
        // by two. The contract matters because offsets drive the excerpt.
        let source = ConfigSource(text: "{\"k\":\"é\"}")
        #expect(source.location(at: 8).column == 9)
    }
}
