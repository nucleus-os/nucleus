import ColliderCore
import Foundation
import Synchronization
import SystemPackage

/// What one source closure hashes to, as planning and revalidation both read
/// it.
///
/// A closure is digested as a whole rather than path by path so that a Git
/// repository is consulted once for every path it owns, and so that the value
/// a plan records is the value revalidation recomputes.
public enum SourceClosureIdentity {
    public static func digest(
        _ paths: [FilePath],
        observe: SourceCaptureObserver? = nil
    ) async throws -> ArtifactDigest {
        try await capture(paths, observe: observe).digest
    }

    /// The same digest, plus the digest of every nested checkout it descended
    /// into on the way.
    ///
    /// Digesting a closure already digests each nested checkout inside it --
    /// that is what makes the outer value depend on them -- and then discards
    /// those values. A caller that needs them per checkout was re-deriving
    /// what this walk had just computed, which meant reading every submodule
    /// twice: 165,175 paths of llvm-project, 31,220 of swift, 12,374 of
    /// hermes, once to reach the closure digest and once more to name it.
    ///
    /// Keeping them is not a second source of truth. Each value is the one the
    /// nested walk produced, so a per-checkout digest and the closure digest
    /// that contains it cannot disagree about what was read.
    public static func capture(
        _ paths: [FilePath],
        observe: SourceCaptureObserver? = nil
    ) async throws -> (digest: ArtifactDigest, nested: [FilePath: ArtifactDigest]) {
        let nested = Mutex<[FilePath: ArtifactDigest]>([:])
        let digest = try await GitSourceCheckoutHasher.digest(
            paths,
            digestNestedCheckout: { checkout in
                let inner = try await capture([checkout], observe: observe)
                nested.withLock {
                    $0[checkout] = inner.digest
                    $0.merge(inner.nested) { existing, _ in existing }
                }
                return inner.digest
            },
            observe: observe)
        return (digest, nested.withLock { $0 })
    }
}

/// Whether the source a run consumed still says what it said when the run
/// planned against it.
///
/// Planning digests every source closure its plan names, so those digests are
/// the run's own statement of what it read, taken at the moment it read them.
/// Revalidation re-reads exactly those closures, which is why a run is
/// superseded by a change to something it consumed rather than by a change
/// anywhere in the checkout.
///
/// Recording is synchronous because it happens inside planning, while reading
/// suspends: the two are separated by a lock rather than by an actor so that a
/// plan is recorded before the execution it describes can begin.
public final class SourceRevalidation: Sendable {
    private let closures = Mutex<[PlannedSourceClosure]>([])

    public init() {}

    /// Records what one plan read. A command that executes several graphs
    /// records each plan as that plan freezes, and every one is revalidated.
    public func record(_ planned: [PlannedSourceClosure]) {
        closures.withLock { recorded in
            for closure in planned where !recorded.contains(closure) {
                recorded.append(closure)
            }
        }
    }

    /// The closures whose source no longer hashes to what planning read.
    ///
    /// Empty when nothing the run consumed has changed, which includes a
    /// command that planned nothing at all. A closure that can no longer be
    /// read is reported as changed, because a run cannot claim source it
    /// cannot account for.
    ///
    /// Closures rather than paths, because a closure is hashed as a whole:
    /// what is known is that something inside one changed, not which of its
    /// paths did.
    public func supersedingClosures() async -> [PlannedSourceClosure] {
        var superseded: [PlannedSourceClosure] = []
        for closure in closures.withLock({ $0 }) {
            let current = try? await SourceClosureIdentity.digest(closure.paths)
            if current != closure.digest {
                superseded.append(closure)
            }
        }
        return superseded
    }
}
