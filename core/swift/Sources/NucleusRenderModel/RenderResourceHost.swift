// Phase 10c.3 cutover — the process-global Swift resource host.
//
// Aggregates the GPU-independent stores the layers resource-host conformers
// (paint/image/snapshot/implicit-action registrars + lifecycles) write and the
// renderer reads at frame time. One process-global instance so a registration
// from any layers context and the renderer's per-frame read share one host.
//
import Synchronization

public final class SwiftResourceHost: Sendable {
    /// The process-global resource host.
    public static let shared = SwiftResourceHost()

    /// Shell-authored paint command lists (refcounted), rasterized at frame time.
    public let paintContents = PaintContentStore()

    /// Snapshot-handle registry (transition prev/next materials, `.snapshot`
    /// content), resolved through to the renderer's texture registry.
    public let snapshots = SnapshotService()

    /// Registered image sources (path + decode bounds, refcounted), decoded by
    /// the renderer at frame time.
    public let images = ImageStore()

    /// Registered SkSL program sources (refcounted), compiled by the renderer
    /// at frame time.
    public let runtimeEffects = RuntimeEffectStore()

    /// Resident implicit-action templates (the layers curve set). The host
    /// installs them as one immutable snapshot so readers never observe a
    /// partially replaced role table.
    private let implicitActionStorage = Mutex(ImplicitActionTable())

    public var implicitActions: ImplicitActionTable {
        implicitActionStorage.withLock { $0 }
    }

    public init() {}

    public func replaceImplicitActions(_ table: ImplicitActionTable) {
        implicitActionStorage.withLock { $0 = table }
    }
}
