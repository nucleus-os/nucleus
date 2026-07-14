import Testing
@testable import NucleusWorkspace

@Test func semanticVersionsCompareNumerically() throws {
    #expect(try SemanticVersion("4.2.3") > SemanticVersion("4.0.0"))
    #expect(try SemanticVersion("1.13.2") > SemanticVersion("1.11"))
    #expect(try SemanticVersion("3.0") == SemanticVersion("3.0.0"))
}
