/// Prepares a configuration source for the JSON decoder.
///
/// Two jobs, one pass:
///
/// 1. **Strip comments by overwriting them with spaces.** Every byte offset in
///    the output matches the input, so a location computed against the original
///    source is still correct after stripping. JSON has no comments and this
///    toolchain's Foundation exposes no JSON5 mode, so this is what makes a
///    hand-edited, annotatable config possible at all.
/// 2. **Pre-validate structure.** Foundation reports every syntax error as one
///    undifferentiated "The given data was not valid JSON" with no offset, which
///    is unusable for a file a person edits by hand. Catching the delimiter and
///    string mistakes here means the common cases carry an exact line and column.
///
/// What this deliberately does *not* do is parse JSON. Literals, colons, commas,
/// and value grammar all remain the decoder's job, where a semantic coding path
/// (`input.touchpad.accel_speed`) is a better diagnostic than a byte offset.
public enum ConfigSyntax {
    private static let space = UInt8(ascii: " ")
    private static let newline = UInt8(ascii: "\n")
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let slash = UInt8(ascii: "/")
    private static let star = UInt8(ascii: "*")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")

    /// Comment-stripped bytes with offsets preserved, or the first structural
    /// defect found.
    public static func prepare(
        _ source: ConfigSource
    ) throws(ConfigSyntaxError) -> [UInt8] {
        let bytes = source.bytes
        var output = bytes
        var stack: [(opener: UInt8, location: SourceLocation)] = []
        var offset = 0

        while offset < bytes.count {
            let byte = bytes[offset]

            if byte == quote {
                offset = try scanString(
                    from: offset, bytes: bytes, source: source)
                continue
            }

            if byte == slash, offset + 1 < bytes.count {
                let next = bytes[offset + 1]
                if next == slash {
                    offset = blankLineComment(from: offset, into: &output)
                    continue
                }
                if next == star {
                    offset = try blankBlockComment(
                        from: offset, into: &output, source: source)
                    continue
                }
            }

            if byte == openBrace || byte == openBracket {
                stack.append((byte, source.location(at: offset)))
            } else if byte == closeBrace || byte == closeBracket {
                let expected = byte == closeBrace ? openBrace : openBracket
                guard let open = stack.popLast() else {
                    throw ConfigSyntaxError(
                        kind: .unmatchedDelimiter(found: byte),
                        location: source.location(at: offset))
                }
                guard open.opener == expected else {
                    throw ConfigSyntaxError(
                        kind: .mismatchedDelimiter(
                            found: byte,
                            expected: open.opener == openBrace
                                ? closeBrace : closeBracket,
                            openedAt: open.location),
                        location: source.location(at: offset))
                }
            }

            offset += 1
        }

        if let unclosed = stack.last {
            throw ConfigSyntaxError(
                kind: .unclosedDelimiter(
                    opener: unclosed.opener, openedAt: unclosed.location),
                location: source.location(at: bytes.count))
        }
        return output
    }

    /// Advance past a string literal. Returns the offset just past the closing
    /// quote.
    ///
    /// A raw newline inside a string is invalid JSON, and in practice it means a
    /// closing quote was forgotten — so it is reported against the *opening*
    /// quote rather than allowed to run to end of input, which would point the
    /// user at the bottom of the file instead of at their typo.
    private static func scanString(
        from start: Int, bytes: [UInt8], source: ConfigSource
    ) throws(ConfigSyntaxError) -> Int {
        var offset = start + 1
        while offset < bytes.count {
            let byte = bytes[offset]
            if byte == backslash {
                offset += 2
                continue
            }
            if byte == quote { return offset + 1 }
            if byte == newline { break }
            offset += 1
        }
        throw ConfigSyntaxError(
            kind: .unterminatedString, location: source.location(at: start))
    }

    /// Overwrite a `//` comment with spaces, stopping before the newline so the
    /// line table is untouched. Returns the offset of the newline (or end).
    private static func blankLineComment(
        from start: Int, into output: inout [UInt8]
    ) -> Int {
        var offset = start
        while offset < output.count, output[offset] != newline {
            output[offset] = space
            offset += 1
        }
        return offset
    }

    /// Overwrite a `/* */` comment with spaces, preserving any newlines inside
    /// it so line numbers after the comment stay correct.
    private static func blankBlockComment(
        from start: Int, into output: inout [UInt8], source: ConfigSource
    ) throws(ConfigSyntaxError) -> Int {
        var offset = start + 2
        output[start] = space
        output[start + 1] = space
        while offset < output.count {
            if output[offset] == star, offset + 1 < output.count,
                output[offset + 1] == slash
            {
                output[offset] = space
                output[offset + 1] = space
                return offset + 2
            }
            if output[offset] != newline { output[offset] = space }
            offset += 1
        }
        throw ConfigSyntaxError(
            kind: .unterminatedBlockComment,
            location: source.location(at: start))
    }
}
