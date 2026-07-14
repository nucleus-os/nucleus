// Operates on UTF-8 byte
// arrays so the segment/case logic matches ASCII semantics exactly
// (all Vulkan identifiers are ASCII).

@inline(__always) func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
@inline(__always) func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
@inline(__always) func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
@inline(__always) func toLower(_ b: UInt8) -> UInt8 { isUpper(b) ? b + 0x20 : b }
@inline(__always) func toUpper(_ b: UInt8) -> UInt8 { isLower(b) ? b - 0x20 : b }

@inline(__always) func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
@inline(__always) func str(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

func eqlIgnoreCase(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Bool {
    if a.count != b.count { return false }
    var ia = a.startIndex, ib = b.startIndex
    while ia < a.endIndex {
        if toLower(a[ia]) != toLower(b[ib]) { return false }
        ia += 1; ib += 1
    }
    return true
}

// Port of id_render.SegmentIterator: split a snake/camel identifier into words at
// underscore and case boundaries.
struct SegmentIterator {
    let text: [UInt8]
    var offset: Int

    init(_ text: [UInt8]) { self.text = text; self.offset = 0 }
    init(_ text: ArraySlice<UInt8>) { self.text = Array(text); self.offset = 0 }

    private func nextBoundary() -> Int {
        var i = offset + 1
        while true {
            if i == text.count || text[i] == 0x5F /* _ */ { return i }
            let prevLower = isLower(text[i - 1])
            let nextLower = isLower(text[i])
            if prevLower && !nextLower {
                return i
            } else if i != offset + 1 && !prevLower && nextLower {
                return i - 1
            }
            i += 1
        }
    }

    mutating func next() -> ArraySlice<UInt8>? {
        while offset < text.count && text[offset] == 0x5F { offset += 1 }
        if offset == text.count { return nil }
        let end = nextBoundary()
        let word = text[offset..<end]
        offset = end
        return word
    }

    func rest() -> ArraySlice<UInt8> {
        if offset >= text.count { return [][...] }
        return text[offset...]
    }
}

struct IdRenderer {
    let tags: [[UInt8]]

    init(tags: [String]) { self.tags = tags.map(bytes) }

    func getAuthorTag(_ id: ArraySlice<UInt8>) -> [UInt8]? {
        for tag in tags where endsWith(id, tag) { return tag }
        return nil
    }

    // Strip the author tag and any trailing underscores left behind.
    func stripAuthorTag(_ id: [UInt8]) -> [UInt8] {
        if let tag = getAuthorTag(id[...]) {
            var s = Array(id[0..<(id.count - tag.count)])
            while let last = s.last, last == 0x5F { s.removeLast() }
            return s
        }
        return id
    }
}

func endsWith(_ s: ArraySlice<UInt8>, _ suffix: [UInt8]) -> Bool {
    if suffix.count > s.count { return false }
    var i = s.endIndex - suffix.count
    var j = 0
    while j < suffix.count {
        if s[i] != suffix[j] { return false }
        i += 1; j += 1
    }
    return true
}

func startsWith(_ s: [UInt8], _ prefix: [UInt8]) -> Bool {
    if prefix.count > s.count { return false }
    for i in 0..<prefix.count where s[i] != prefix[i] { return false }
    return true
}

// Port of swift_render.writeCamel: lowerCamel (or UpperCamel when title), digits
// passed through, author tag appended verbatim.
func writeCamel(_ buf: inout [UInt8], title: Bool, _ id: ArraySlice<UInt8>, _ tag: [UInt8]?) {
    var it = SegmentIterator(id)
    var lowerFirst = !title
    while let segment = it.next() {
        var i = segment.startIndex
        while i < segment.endIndex && isDigit(segment[i]) {
            buf.append(segment[i]); i += 1
        }
        if i == segment.endIndex { continue }
        if i == segment.startIndex && lowerFirst {
            buf.append(toLower(segment[i]))
        } else {
            buf.append(toUpper(segment[i]))
        }
        lowerFirst = false
        var j = i + 1
        while j < segment.endIndex { buf.append(toLower(segment[j])); j += 1 }
    }
    if let tag { buf.append(contentsOf: tag) }
}

func sanitize(_ ident: [UInt8]) -> String {
    if ident.isEmpty { return "value" }
    let s = str(ident)
    if isSwiftKeyword(s) { return "`\(s)`" }
    if isDigit(ident[0]) { return "_\(s)" }
    return s
}

func isSwiftKeyword(_ s: String) -> Bool {
    swiftKeywords.contains(s)
}

let swiftKeywords: Set<String> = [
    "associatedtype", "borrowing", "class", "consuming", "deinit",
    "enum", "extension", "fileprivate", "func", "import",
    "init", "inout", "internal", "let", "open",
    "operator", "private", "precedencegroup", "protocol", "public",
    "rethrows", "static", "struct", "subscript", "typealias",
    "var", "break", "case", "continue", "default",
    "defer", "do", "else", "fallthrough", "for",
    "guard", "if", "in", "repeat", "return",
    "switch", "where", "while", "as", "false",
    "is", "nil", "self", "Self", "super",
    "throw", "throws", "true", "try", "Any",
    "catch", "Protocol", "Type", "any", "some",
]

func trimVkNamespace(_ id: [UInt8]) -> ArraySlice<UInt8> {
    let prefixes = [bytes("VK_"), bytes("PFN_vk"), bytes("vk"), bytes("Vk")]
    for p in prefixes where startsWith(id, p) {
        return id[p.count...]
    }
    return id[...]
}
