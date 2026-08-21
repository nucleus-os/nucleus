/// A readable rendering of the bytes an `IdentityEncoder` produced.
///
/// Two identities that disagree are two byte strings, and a digest says only
/// that they differ. Isolating which component differs otherwise means
/// bisecting a build system against a second checkout, one round trip per
/// hypothesis. The encoder's framing is self-describing, so the components can
/// simply be read back rather than instrumented at every append site.
public enum IdentityTrace {
    public indirect enum Node: Sendable {
        case bytes([UInt8])
        case nested([Node])
        case string(String)
        case integer(UInt64)
        case boolean(Bool)
        case path(String)
        case enumeration(String)
        case optional([Node]?)
        case record([Node])
        case sequence([[Node]])
    }

    /// Decodes one encoder's output, or nil when the bytes are not a complete
    /// encoder stream. Callers rely on the nil to distinguish spliced identity
    /// bytes from an opaque digest, which are both appended as `bytes`.
    public static func decode(_ bytes: [UInt8]) -> [Node]? {
        guard !bytes.isEmpty, let nodes = parse(bytes) else { return nil }
        return nodes
    }

    /// Decodes a payload known to be an encoder stream, where empty is the
    /// empty component list rather than a parse failure.
    static func parse(_ bytes: [UInt8]) -> [Node]? {
        var reader = Reader(bytes)
        var nodes: [Node] = []
        while !reader.isAtEnd {
            guard let node = reader.readNode() else { return nil }
            nodes.append(node)
        }
        return nodes
    }

    /// Renders decoded components as indented lines, one component per line.
    public static func render(_ nodes: [Node], indent: Int = 0) -> [String] {
        var lines: [String] = []
        let pad = String(repeating: "  ", count: indent)
        for node in nodes {
            switch node {
            case .string(let value):
                lines.append("\(pad)string \(quoted(value))")
            case .path(let value):
                lines.append("\(pad)path \(quoted(value))")
            case .enumeration(let value):
                lines.append("\(pad)enum \(quoted(value))")
            case .integer(let value):
                lines.append("\(pad)integer \(value)")
            case .boolean(let value):
                lines.append("\(pad)boolean \(value)")
            case .bytes(let value):
                lines.append("\(pad)bytes(\(value.count)) \(hexadecimal(value))")
            case .nested(let children):
                lines.append("\(pad)bytes nested")
                lines += render(children, indent: indent + 1)
            case .optional(let children):
                guard let children else {
                    lines.append("\(pad)optional none")
                    continue
                }
                lines.append("\(pad)optional")
                lines += render(children, indent: indent + 1)
            case .record(let children):
                lines.append("\(pad)record")
                lines += render(children, indent: indent + 1)
            case .sequence(let elements):
                lines.append("\(pad)sequence(\(elements.count))")
                for (offset, element) in elements.enumerated() {
                    lines.append("\(pad)  [\(offset)]")
                    lines += render(element, indent: indent + 2)
                }
            }
        }
        return lines
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value)\""
    }

    private static func hexadecimal(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var rendered = ""
        for byte in bytes.prefix(16) {
            rendered.append(digits[Int(byte >> 4)])
            rendered.append(digits[Int(byte & 0x0f)])
        }
        return bytes.count > 16 ? rendered + "…" : rendered
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var offset: Int

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            offset = 0
        }

        var isAtEnd: Bool { offset == bytes.count }

        mutating func readNode() -> Node? {
            guard let type = readByte(), let payload = readFrame() else { return nil }
            switch type {
            case 1:
                guard let children = IdentityTrace.decode(payload) else {
                    return .bytes(payload)
                }
                return .nested(children)
            case 2:
                return String(bytes: payload, encoding: .utf8).map(Node.string)
            case 3:
                guard payload.count == 8 else { return nil }
                return .integer(payload.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            case 4:
                guard payload.count == 1 else { return nil }
                return .boolean(payload[0] != 0)
            case 5:
                return String(bytes: payload, encoding: .utf8).map(Node.path)
            case 6:
                return String(bytes: payload, encoding: .utf8).map(Node.enumeration)
            case 7:
                guard let flag = payload.first else { return nil }
                guard flag != 0 else { return payload.count == 1 ? .optional(nil) : nil }
                var nested = Reader(Array(payload.dropFirst()))
                guard let framed = nested.readFrame(), nested.isAtEnd,
                    let children = IdentityTrace.parse(framed)
                else { return nil }
                return .optional(children)
            case 8:
                guard let children = IdentityTrace.parse(payload) else { return nil }
                return .record(children)
            case 9:
                var nested = Reader(payload)
                guard let count = nested.readLength() else { return nil }
                var elements: [[Node]] = []
                for _ in 0..<count {
                    guard let framed = nested.readFrame() else { return nil }
                    guard let element = IdentityTrace.parse(framed) else { return nil }
                    elements.append(element)
                }
                guard nested.isAtEnd else { return nil }
                return .sequence(elements)
            default:
                return nil
            }
        }

        private mutating func readByte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func readLength() -> Int? {
            guard offset + 8 <= bytes.count else { return nil }
            let value = bytes[offset..<(offset + 8)].reduce(UInt64(0)) {
                $0 << 8 | UInt64($1)
            }
            guard value <= UInt64(Int.max) else { return nil }
            offset += 8
            return Int(value)
        }

        mutating func readFrame() -> [UInt8]? {
            guard let length = readLength(), offset + length <= bytes.count else {
                return nil
            }
            defer { offset += length }
            return Array(bytes[offset..<(offset + length)])
        }
    }
}
