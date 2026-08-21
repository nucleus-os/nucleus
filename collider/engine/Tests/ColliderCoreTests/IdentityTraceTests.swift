import SystemPackage
import Testing

@testable import ColliderCore

@Test func identityTraceReadsBackEveryEncodedComponentKind() {
    var encoder = IdentityEncoder(
        identityPathMap: IdentityPathMap(roots: [
            IdentityPathRoot(name: "workspace", path: FilePath("/first/checkout"))
        ]))
    encoder.append("name")
    encoder.append(UInt64(7))
    encoder.append(true)
    encoder.append(path: FilePath("/first/checkout/Sources"))
    encoder.append(argument: "-I/first/checkout/include")
    encoder.appendOptional("value") { $0.append($1) }
    encoder.appendOptional(String?.none) { $0.append($1) }
    encoder.appendRecord { $0.append("inside") }
    encoder.appendSequence(["a", "b"]) { $0.append($1) }

    let nodes = try! #require(IdentityTrace.decode(encoder.bytes))
    let rendered = IdentityTrace.render(nodes).joined(separator: "\n")

    #expect(rendered.contains("string \"name\""))
    #expect(rendered.contains("integer 7"))
    #expect(rendered.contains("boolean true"))
    #expect(rendered.contains("path \"${workspace}/Sources\""))
    #expect(rendered.contains("string \"-I${workspace}/include\""))
    #expect(rendered.contains("optional none"))
    #expect(rendered.contains("record"))
    #expect(rendered.contains("sequence(2)"))
}

@Test func identityTraceDecodesSplicedIdentityBytesAndRejectsOpaqueDigests() {
    var inner = IdentityEncoder()
    inner.append("spliced")
    var encoder = IdentityEncoder()
    encoder.append(bytes: inner.bytes)
    encoder.append(bytes: Array(repeating: 0xab, count: 32))

    let nodes = try! #require(IdentityTrace.decode(encoder.bytes))
    let rendered = IdentityTrace.render(nodes).joined(separator: "\n")

    #expect(rendered.contains("bytes nested"))
    #expect(rendered.contains("string \"spliced\""))
    #expect(rendered.contains("bytes(32) abababababababababababababababab…"))
}

@Test func identityTraceRejectsBytesThatAreNotAnEncoderStream() {
    #expect(IdentityTrace.decode([]) == nil)
    #expect(IdentityTrace.decode([99, 0, 0, 0, 0, 0, 0, 0, 0]) == nil)
}
