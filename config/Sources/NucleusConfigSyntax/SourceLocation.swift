/// A position in a configuration source, resolved from a UTF-8 byte offset.
///
/// Offsets are the authority; line and column are derived for presentation.
/// The syntax layer preserves byte offsets exactly when it strips comments, so
/// a location computed against the original text stays correct for diagnostics
/// raised anywhere downstream.
package struct SourceLocation: Equatable, Hashable, Sendable {
    /// UTF-8 byte offset from the start of the source.
    package let offset: Int
    /// 1-based line number.
    package let line: Int
    /// 1-based column, counted in UTF-8 bytes from the start of the line.
    package let column: Int

    package init(offset: Int, line: Int, column: Int) {
        self.offset = offset
        self.line = line
        self.column = column
    }
}

extension SourceLocation: CustomStringConvertible {
    package var description: String { "\(line):\(column)" }
}

/// A UTF-8 view of one configuration source with offset → line/column mapping.
///
/// The line table is built once. Locating an offset is a binary search rather
/// than a rescan, so a diagnostic pass that resolves many locations stays
/// linear in the number of diagnostics rather than in source length.
package struct ConfigSource: Sendable {
    /// The original bytes, before any comment stripping.
    package let bytes: [UInt8]
    /// Byte offset of the first character of each line.
    private let lineStarts: [Int]

    package init(text: String) {
        self.init(bytes: Array(text.utf8))
    }

    package init(bytes: [UInt8]) {
        self.bytes = bytes
        var starts = [0]
        for offset in bytes.indices where bytes[offset] == UInt8(ascii: "\n") {
            starts.append(offset + 1)
        }
        self.lineStarts = starts
    }

    /// The location of a byte offset. Offsets past the end clamp to the end,
    /// so an "unexpected end of input" diagnostic still resolves.
    package func location(at offset: Int) -> SourceLocation {
        let clamped = max(0, min(offset, bytes.count))
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= clamped { low = mid } else { high = mid - 1 }
        }
        return SourceLocation(
            offset: clamped,
            line: low + 1,
            column: clamped - lineStarts[low] + 1)
    }

    /// The text of one 1-based line, without its terminator. Used to render a
    /// diagnostic's source excerpt.
    package func line(_ number: Int) -> String {
        guard number >= 1, number <= lineStarts.count else { return "" }
        let start = lineStarts[number - 1]
        var end = number < lineStarts.count ? lineStarts[number] : bytes.count
        while end > start,
            bytes[end - 1] == UInt8(ascii: "\n")
                || bytes[end - 1] == UInt8(ascii: "\r")
        {
            end -= 1
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}
