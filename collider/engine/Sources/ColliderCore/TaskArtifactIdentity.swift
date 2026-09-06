import SystemPackage

/// Final cache identity uses consumed output content, never its producer's
/// recipe. The recipe already names each reference and its portable path.
package enum TaskArtifactIdentity {
    package static func resolve(
        recipe: ArtifactDigest,
        task: TaskDeclaration,
        dependencyIdentity: (TaskID) throws -> ArtifactDigest,
        digest: (ArtifactReference) throws -> ArtifactDigest
    ) throws -> ArtifactDigest {
        guard !task.artifactReferences.isEmpty || !task.identityDependencies.isEmpty else {
            return recipe
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
        return .sha256(encoder.bytes)
    }
}
