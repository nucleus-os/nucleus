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

    package func validate(repositoryRoot: FilePath) throws {
        _ = try ProductArtifactSourceSnapshot.capture(
            repositoryRoot: repositoryRoot,
            sourceAuthority: .protectedMain,
            assertedCommit: commit,
            assertedBranch: "refs/heads/main")
    }
}
