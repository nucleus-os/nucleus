/// A parsed `data:` URI.
///
/// Applications put images directly in icon fields often enough that treating one
/// as a file path fails for no reason — the same argument that makes an absolute
/// path resolve directly in the icon theme resolver.
///
/// Only the payload matters here. The media type is parsed but not enforced: the
/// decoder sniffs content anyway, so a mislabelled `data:text/plain` holding a PNG
/// decodes correctly, and a correctly-labelled one holding garbage does not.
public struct DataURI: Equatable, Sendable {
    public var mediaType: String
    public var bytes: [UInt8]

    /// Parse a `data:` URI, or return nil if it is not one.
    public static func parse(_ uri: String) -> DataURI? {
        guard uri.hasPrefix("data:") else { return nil }
        let body = uri.dropFirst("data:".count)
        guard let comma = body.firstIndex(of: ",") else { return nil }

        let header = String(body[body.startIndex..<comma])
        let payload = String(body[body.index(after: comma)...])

        let isBase64 = header.hasSuffix(";base64")
        let mediaType = isBase64
            ? String(header.dropLast(";base64".count))
            : header

        guard let bytes = isBase64
            ? decodeBase64(payload)
            : decodePercentEncoding(payload)
        else { return nil }

        return DataURI(mediaType: mediaType, bytes: bytes)
    }

    /// Decode base64, tolerating missing padding and embedded whitespace.
    ///
    /// Both are common in hand-assembled URIs, and rejecting them would fail on
    /// data that every other consumer accepts.
    static func decodeBase64(_ text: String) -> [UInt8]? {
        var accumulator: UInt32 = 0
        var bitCount = 0
        var out: [UInt8] = []

        for character in text.unicodeScalars {
            if character == "=" { break }
            if character == " " || character == "\n" || character == "\r" || character == "\t" {
                continue
            }
            guard let value = base64Value(character) else { return nil }
            accumulator = (accumulator << 6) | UInt32(value)
            bitCount += 6
            if bitCount >= 8 {
                bitCount -= 8
                out.append(UInt8((accumulator >> UInt32(bitCount)) & 0xFF))
            }
        }
        return out
    }

    private static func base64Value(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "A"..."Z": return UInt8(scalar.value - Unicode.Scalar("A").value)
        case "a"..."z": return UInt8(scalar.value - Unicode.Scalar("a").value) + 26
        case "0"..."9": return UInt8(scalar.value - Unicode.Scalar("0").value) + 52
        case "+": return 62
        case "/": return 63
        default: return nil
        }
    }

    static func decodePercentEncoding(_ text: String) -> [UInt8]? {
        var out: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        var pending: [UInt8] = []
        while let byte = iterator.next() { pending.append(byte) }

        var index = 0
        while index < pending.count {
            if pending[index] == UInt8(ascii: "%") {
                guard index + 2 < pending.count,
                      let high = hexValue(pending[index + 1]),
                      let low = hexValue(pending[index + 2])
                else { return nil }
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(pending[index])
                index += 1
            }
        }
        return out
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
