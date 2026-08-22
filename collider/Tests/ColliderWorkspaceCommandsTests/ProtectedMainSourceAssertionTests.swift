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

@Test func runProvenanceClassifiesVerificationLocalAndHalfConfiguredRunners() throws {
    let commit = String(repeating: "b", count: 40)
    let complete = [
        "NUCLEUS_PRODUCT_SOURCE_AUTHORITY": "protected-main",
        "NUCLEUS_PRODUCT_SOURCE_COMMIT": commit,
        "NUCLEUS_PRODUCT_SOURCE_REF": "refs/heads/main",
        "NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN": "nucleus-builder",
    ]
    let verification = try ProtectedMainSourceAssertion.runProvenance(
        environment: complete)
    #expect(verification.sourceAuthority == .protectedMain)
    #expect(verification.sourceCommit == commit)
    #expect(verification.producerTrustDomain == .nucleusBuilder)

    #expect(try ProtectedMainSourceAssertion.runProvenance(environment: [:]) == .local)
    #expect(
        try ProtectedMainSourceAssertion.runProvenance(environment: [
            "NUCLEUS_PRODUCT_SOURCE_AUTHORITY": "local-development"
        ]) == .local)

    // A runner that claims the authority but not the rest of the contract is
    // refused rather than silently recorded as ordinary local work.
    for name in complete.keys where name != "NUCLEUS_PRODUCT_SOURCE_AUTHORITY" {
        var incomplete = complete
        incomplete.removeValue(forKey: name)
        #expect(throws: WorkspaceFailure.self) {
            try ProtectedMainSourceAssertion.runProvenance(environment: incomplete)
        }
    }
}
