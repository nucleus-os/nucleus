import ColliderCore
import Testing

@testable import ColliderWorkspaceCommands

@Test func protectedMainSourceAssertionRequiresTheCompleteCIContract() throws {
    let complete = [
        "NUCLEUS_PRODUCT_SOURCE_AUTHORITY": "protected-main",
        "NUCLEUS_PRODUCT_SOURCE_COMMIT": String(repeating: "a", count: 40),
        "NUCLEUS_PRODUCT_SOURCE_REF": "refs/heads/main",
        "NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN": "nucleus-builder",
    ]
    #expect(
        try ProtectedMainSourceAssertion(environment: complete).commit
            == String(repeating: "a", count: 40))

    for name in complete.keys {
        var incomplete = complete
        incomplete.removeValue(forKey: name)
        #expect(throws: WorkspaceFailure.self) {
            try ProtectedMainSourceAssertion(environment: incomplete)
        }
    }

    var local = complete
    local["NUCLEUS_PRODUCT_SOURCE_AUTHORITY"] =
        ProductArtifactSourceAuthority.localDevelopment.rawValue
    #expect(throws: WorkspaceFailure.self) {
        try ProtectedMainSourceAssertion(environment: local)
    }
}
