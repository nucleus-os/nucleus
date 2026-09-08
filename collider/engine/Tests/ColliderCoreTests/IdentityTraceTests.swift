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

@Test func leakedPlacementIsReportedByRootAndOffendingComponent() throws {
    let cache = IdentityPathRoot(name: "cache", path: FilePath("/machine/cache"))
    let workspace = IdentityPathRoot(
        name: "workspace",
        path: FilePath("/machine/checkout"))
    let map = IdentityPathMap(roots: [cache, workspace])
    var encoder = IdentityEncoder(identityPathMap: map)
    // A container target and a working directory, which are plain strings
    // because they name the container rather than this host.
    encoder.append("/machine/cache/products")
    encoder.appendRecord { $0.append("/machine/checkout") }
    encoder.appendSequence(["/machine/cache/products/tool", "unrelated"]) {
        $0.append($1)
    }
    // Canonicalized appends carry no root and must not be reported.
    encoder.append(path: FilePath("/machine/cache/scratch"))

    let leaked = map.declaredRoots(inEncoded: encoder.bytes)
    #expect(Set(leaked.map(\.name)) == ["cache", "workspace"])

    let nodes = try #require(IdentityTrace.decode(encoder.bytes))
    #expect(
        IdentityTrace.componentsContaining(cache.path.string, in: nodes) == [
            "/machine/cache/products", "/machine/cache/products/tool",
        ])
    #expect(
        IdentityTrace.componentsContaining(workspace.path.string, in: nodes) == [
            "/machine/checkout"
        ])
    #expect(IdentityTrace.componentsContaining("unrelated", in: nodes) == ["unrelated"])
}

@Test func identityDifferenceNamesTheComponentThatChanged() throws {
    func encoded(lock: String, tool: [UInt8]) -> [IdentityTrace.Node] {
        var encoder = IdentityEncoder()
        encoder.append("swift-package-dependencies")
        encoder.appendSequence(["Package.swift", lock]) { $0.append($1) }
        encoder.append(bytes: tool)
        return IdentityTrace.decode(encoder.bytes) ?? []
    }

    let recorded = encoded(lock: "Package.resolved", tool: [1, 2, 3])
    let planned = encoded(lock: "Package.resolved", tool: [4, 5, 6])
    let difference = IdentityTrace.difference(
        recorded: recorded, planned: planned
    ).joined(separator: "\n")

    // The digest of the resolved tool, not the lockfile beside it. Naming the
    // component is the whole point: both identities are one digest otherwise.
    #expect(difference.contains("bytes(3) 010203"))
    #expect(difference.contains("bytes(3) 040506"))
    #expect(!difference.contains("Package.resolved"))
    #expect(!difference.contains("swift-package-dependencies"))
}

@Test func identityDifferenceLocatesAChangeInsideASequence() throws {
    func encoded(second: String) -> [IdentityTrace.Node] {
        var encoder = IdentityEncoder()
        encoder.appendSequence(["first", second, "third"]) { $0.append($1) }
        return IdentityTrace.decode(encoder.bytes) ?? []
    }

    let difference = IdentityTrace.difference(
        recorded: encoded(second: "second"),
        planned: encoded(second: "changed"))

    let location = try #require(difference.first)
    #expect(location.contains("[0] > [1]"))
    #expect(difference.contains { $0.contains("recorded") && $0.contains("second") })
    #expect(difference.contains { $0.contains("planned") && $0.contains("changed") })
}

@Test func identityDifferenceReportsAShapeChangeRatherThanComparingPastIt() throws {
    var shorter = IdentityEncoder()
    shorter.appendSequence(["one"]) { $0.append($1) }
    var longer = IdentityEncoder()
    longer.appendSequence(["one", "two"]) { $0.append($1) }

    let difference = IdentityTrace.difference(
        recorded: IdentityTrace.decode(shorter.bytes) ?? [],
        planned: IdentityTrace.decode(longer.bytes) ?? []
    ).joined(separator: "\n")

    #expect(difference.contains("sequence(1)"))
    #expect(difference.contains("sequence(2)"))
}

@Test func identicalIdentitiesHaveNoDifference() {
    var encoder = IdentityEncoder()
    encoder.append("same")
    encoder.appendSequence(["a", "b"]) { $0.append($1) }
    let nodes = IdentityTrace.decode(encoder.bytes) ?? []

    #expect(IdentityTrace.difference(recorded: nodes, planned: nodes).isEmpty)
}
