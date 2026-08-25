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
        try await GitSourceCheckoutHasher.digest(
            paths,
            digestNestedCheckout: { try await digest([$0], observe: observe) },
            observe: observe)
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

    /// The paths whose source no longer hashes to what planning read.
    ///
    /// Empty when nothing the run consumed has changed, which includes a
    /// command that planned nothing at all. A closure that can no longer be
    /// read is reported as changed, because a run cannot claim source it
    /// cannot account for.
    public func supersedingPaths() async -> [FilePath] {
        var superseded: Set<FilePath> = []
        for closure in closures.withLock({ $0 }) {
            let current = try? await SourceClosureIdentity.digest(closure.paths)
            if current != closure.digest {
                superseded.formUnion(closure.paths)
            }
        }
        return superseded.sorted { $0.string < $1.string }
    }
}
