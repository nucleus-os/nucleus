import Testing

@testable import ColliderWorkspaceCommands

@Test func parsesACompilerDiagnosticLocation() {
    let parsed = SourceDiagnosticLocator.parse(
        "/nucleus-workspace/core/swift/Sources/A.swift:166:16: error: type 'X' does not conform")
    #expect(parsed?.path == "/nucleus-workspace/core/swift/Sources/A.swift")
    #expect(parsed?.line == 166)
    #expect(parsed?.column == 16)
    #expect(parsed?.message == "type 'X' does not conform")
}

@Test func parsesAFatalDiagnosticLocation() {
    let parsed = SourceDiagnosticLocator.parse("/a/b/C.swift:3:1: fatal error: boom")
    #expect(parsed?.line == 3 && parsed?.message == "boom")
}

/// A driver's terminal `error:` line names no source location, so it must not
/// be mistaken for one.
@Test func rejectsADiagnosticWithoutALocation() {
    #expect(SourceDiagnosticLocator.parse("error: fatalError") == nil)
    #expect(SourceDiagnosticLocator.parse("swift-build: error: link failed") == nil)
}

@Test func rejectsANonPositiveLocation() {
    #expect(SourceDiagnosticLocator.parse("/a/B.swift:0:1: error: x") == nil)
    #expect(SourceDiagnosticLocator.parse("/a/B.swift:1:0: error: x") == nil)
    #expect(SourceDiagnosticLocator.parse("/a/B.swift:x:1: error: x") == nil)
}

@Test func resolvesTheLongestSuffixThatNamesACheckoutFile() {
    let resolved = SourceDiagnosticLocator.repositoryRelativePath(
        for: "/nucleus-workspace/core/swift/Sources/A.swift",
        repositoryRoot: "/checkout",
        exists: { $0 == "/checkout/core/swift/Sources/A.swift" })
    #expect(resolved == "core/swift/Sources/A.swift")
}

/// The container mount prefix is not known here, so the first candidate that
/// exists wins; a longer one that does not exist must not be preferred.
@Test func skipsCandidatesThatDoNotExist() {
    var probed: [String] = []
    let resolved = SourceDiagnosticLocator.repositoryRelativePath(
        for: "/a/b/c/D.swift",
        repositoryRoot: "/checkout",
        exists: {
            probed.append($0)
            return $0 == "/checkout/c/D.swift"
        })
    #expect(resolved == "c/D.swift")
    #expect(probed.first == "/checkout/a/b/c/D.swift")
}

/// One trailing component names too many plausible files to attribute a
/// failure, so it is never resolved even when it exists.
@Test func refusesToAttributeASingleComponent() {
    #expect(
        SourceDiagnosticLocator.repositoryRelativePath(
            for: "/a/D.swift",
            repositoryRoot: "/checkout",
            exists: { _ in true }) == "a/D.swift")
    #expect(
        SourceDiagnosticLocator.repositoryRelativePath(
            for: "D.swift",
            repositoryRoot: "/checkout",
            exists: { _ in true }) == nil)
}

@Test func yieldsNoLocationWhenNothingResolves() {
    #expect(
        SourceDiagnosticLocator.firstDiagnostic(
            in: "/elsewhere/X.swift:1:1: error: boom",
            repositoryRoot: "/checkout",
            exists: { _ in false }) == nil)
}

/// A log usually blames a dependency checkout before it blames the repository.
/// The annotation has to land on the file a reader can open.
@Test func selectsTheFirstDiagnosticThatResolves() throws {
    let log = """
        /deps/Vendor.swift:9:2: error: vendored failure
        warning: unrelated
        /nucleus-workspace/core/A.swift:4:7: error: real failure
        /nucleus-workspace/core/B.swift:5:1: error: later failure
        """
    let diagnostic = try #require(
        SourceDiagnosticLocator.firstDiagnostic(
            in: log,
            repositoryRoot: "/checkout",
            exists: { $0.hasPrefix("/checkout/core/") }))
    #expect(diagnostic.path == "core/A.swift")
    #expect(diagnostic.line == 4 && diagnostic.column == 7)
    #expect(diagnostic.message == "real failure")
}

@Test func toleratesATrailingSeparatorOnTheRoot() {
    #expect(
        SourceDiagnosticLocator.repositoryRelativePath(
            for: "/m/core/A.swift",
            repositoryRoot: "/checkout/",
            exists: { $0 == "/checkout/core/A.swift" }) == "core/A.swift")
}
