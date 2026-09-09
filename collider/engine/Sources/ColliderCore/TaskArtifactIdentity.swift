import SystemPackage

/// Final cache identity uses consumed output content, never its producer's
/// recipe. The recipe already names each reference and its portable path.
package enum TaskArtifactIdentity {
    /// A resolved identity together with the encoding it was taken over.
    ///
    /// The digest says a task must run again. The components say which
    /// consumed artifact or dependency stopped matching, which is the only
    /// question left once a rerun is known to be needed. They are the same
    /// bytes the digest is taken of, so keeping them costs a copy and changes
    /// no identity.
    ///
    /// `components` is nil where the recipe stood unchanged, because the
    /// recipe's own encoding already describes that identity in full.
    package struct Resolution {
        package let digest: ArtifactDigest
        package let components: [UInt8]?

        package init(digest: ArtifactDigest, components: [UInt8]?) {
            self.digest = digest
            self.components = components
        }
    }

    package static func resolve(
        recipe: ArtifactDigest,
        task: TaskDeclaration,
        dependencyIdentity: (TaskID) throws -> ArtifactDigest,
        digest: (ArtifactReference) throws -> ArtifactDigest
    ) throws -> Resolution {
        guard !task.artifactReferences.isEmpty || !task.identityDependencies.isEmpty else {
            return Resolution(digest: recipe, components: nil)
        }
        var encoder = IdentityEncoder()
        encoder.append(digest: recipe)
        try encoder.appendSequence(task.identityDependencies.sorted { $0.rawValue < $1.rawValue }) {
            entry, dependency in
            entry.append(digest: try dependencyIdentity(dependency))
        }
        let references = task.artifactReferences.sorted {
            ($0.producer.rawValue, $0.slot.rawValue, $0.path.string)
                < ($1.producer.rawValue, $1.slot.rawValue, $1.path.string)
        }
        try encoder.appendSequence(references) { entry, reference in
            entry.append(digest: try digest(reference))
        }
        return Resolution(digest: .sha256(encoder.bytes), components: encoder.bytes)
    }
}
