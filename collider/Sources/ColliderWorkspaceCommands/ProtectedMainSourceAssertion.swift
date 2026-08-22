import ColliderCore
import ColliderPersistence
import SystemPackage

package struct ProtectedMainSourceAssertion: Equatable, Sendable {
    package let commit: String

    package init(environment: [String: String]) throws {
        guard
            environment["NUCLEUS_PRODUCT_SOURCE_AUTHORITY"]
                == ProductArtifactSourceAuthority.protectedMain.rawValue
        else {
            throw WorkspaceFailure.message(
                "protected-main verification requires "
                    + "NUCLEUS_PRODUCT_SOURCE_AUTHORITY=protected-main")
        }
        guard
            let commit = environment["NUCLEUS_PRODUCT_SOURCE_COMMIT"],
            !commit.isEmpty
        else {
            throw WorkspaceFailure.message(
                "protected-main verification requires "
                    + "NUCLEUS_PRODUCT_SOURCE_COMMIT")
        }
        guard environment["NUCLEUS_PRODUCT_SOURCE_REF"] == "refs/heads/main"
        else {
            throw WorkspaceFailure.message(
                "protected-main verification requires "
                    + "NUCLEUS_PRODUCT_SOURCE_REF=refs/heads/main")
        }
        guard
            environment["NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN"]
                == ProductArtifactProducerTrustDomain.nucleusBuilder.rawValue
        else {
            throw WorkspaceFailure.message(
                "protected-main verification requires "
                    + "NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN=nucleus-builder")
        }
        self.commit = commit
    }

    package func validate(
        repositoryRoot: FilePath,
        observe: SourceCaptureObserver? = nil
    ) throws {
        _ = try ProductArtifactSourceSnapshot.capture(
            repositoryRoot: repositoryRoot,
            sourceAuthority: .protectedMain,
            assertedCommit: commit,
            assertedBranch: "refs/heads/main",
            observe: observe)
    }
}

extension ProtectedMainSourceAssertion {
    /// Classifies the invocation so its run record can be retained on its own
    /// terms. An environment that claims an authority must claim the whole
    /// contract: a half-configured runner recording itself as local would
    /// leave a verification failure indistinguishable from a local one.
    ///
    /// Only an account that executes builds directly can make the claim at
    /// all. Elevation reaches the builder through a launcher that discards the
    /// caller's environment, so a local operator exporting these names cannot
    /// mint a verification record; the automated runner is already the builder
    /// and needs no elevation.
    package static func runProvenance(
        environment: [String: String]
    ) throws -> RunProvenance {
        guard let authority = environment["NUCLEUS_PRODUCT_SOURCE_AUTHORITY"] else {
            return .local
        }
        if authority == ProductArtifactSourceAuthority.localDevelopment.rawValue {
            return .local
        }
        let assertion = try ProtectedMainSourceAssertion(environment: environment)
        return RunProvenance(
            sourceAuthority: .protectedMain,
            sourceCommit: assertion.commit,
            producerTrustDomain: .nucleusBuilder)
    }
}
