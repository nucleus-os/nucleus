/// A structural defect found while preparing a configuration source.
///
/// These are the mistakes hand-editing actually produces: an unclosed brace, a
/// forgotten quote, a stray bracket. Each carries an exact location, which is
/// what Foundation's JSON parser cannot supply — it reports every syntax error
/// as one undifferentiated "not valid JSON". Anything subtler than the cases
/// here is left to the decoder, where a semantic coding path is the better
/// diagnostic anyway.
package struct ConfigSyntaxError: Error, Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// A string literal ran to end of input.
        case unterminatedString
        /// A `/*` block comment ran to end of input.
        case unterminatedBlockComment
        /// A closing delimiter with nothing open.
        case unmatchedDelimiter(found: UInt8)
        /// A closing delimiter that does not match the innermost open one.
        case mismatchedDelimiter(
            found: UInt8, expected: UInt8, openedAt: SourceLocation)
        /// A delimiter still open at end of input.
        case unclosedDelimiter(opener: UInt8, openedAt: SourceLocation)
    }

    package let kind: Kind
    /// Where the defect was detected. For an unclosed delimiter this is end of
    /// input; `kind` carries the opening location, which is the more useful of
    /// the two to point a user at.
    package let location: SourceLocation

    package init(kind: Kind, location: SourceLocation) {
        self.kind = kind
        self.location = location
    }

    /// The location a user should be sent to, which is not always where the
    /// defect was detected.
    package var primaryLocation: SourceLocation {
        switch kind {
        case .unclosedDelimiter(_, let openedAt): openedAt
        case .unterminatedString, .unterminatedBlockComment,
            .unmatchedDelimiter, .mismatchedDelimiter:
            location
        }
    }

    package var message: String {
        switch kind {
        case .unterminatedString:
            "unterminated string"
        case .unterminatedBlockComment:
            "unterminated block comment"
        case .unmatchedDelimiter(let found):
            "unexpected '\(Character(UnicodeScalar(found)))'"
        case .mismatchedDelimiter(let found, let expected, let openedAt):
            "expected '\(Character(UnicodeScalar(expected)))' to close the "
                + "'\(Character(UnicodeScalar(openingDelimiter(for: expected))))' "
                + "opened at \(openedAt), found "
                + "'\(Character(UnicodeScalar(found)))'"
        case .unclosedDelimiter(let opener, _):
            "unclosed '\(Character(UnicodeScalar(opener)))'"
        }
    }
}

private func openingDelimiter(for closer: UInt8) -> UInt8 {
    closer == UInt8(ascii: "}") ? UInt8(ascii: "{") : UInt8(ascii: "[")
}
