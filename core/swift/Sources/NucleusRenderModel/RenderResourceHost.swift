// Aggregates the GPU-independent stores the layers resource-host conformers
// (paint/image/snapshot/implicit-action registrars + lifecycles) write and the
// renderer reads at frame time. Each runtime graph owns exactly one instance.
//
import Synchronization

public struct ResourceHostIdentity: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "resource-host identity must be nonzero")
        self.rawValue = rawValue
    }
}

public final class SwiftResourceHost: Sendable {
    private static let identitySequence = Mutex(UInt64(1))

    public let identity: ResourceHostIdentity
    private let live = Mutex(true)
    /// Shell-authored paint command lists (refcounted), rasterized at frame time.
    public let paintContents = PaintContentStore()

    /// Snapshot-handle registry for `.snapshot` content, resolved through to
    /// the renderer's texture registry.
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

    public init() {
        let rawIdentity = Self.identitySequence.withLock { next in
            let current = next
            next &+= 1
            precondition(next != 0, "resource-host identity space exhausted")
            return current
        }
        identity = ResourceHostIdentity(rawValue: rawIdentity)
    }

    public var isLive: Bool { live.withLock { $0 } }

    public func accepts(rawIdentity: UInt64) -> Bool {
        rawIdentity == identity.rawValue && isLive
    }

    /// Reject every late registrar/lifecycle callback before the runtime-owned
    /// stores begin teardown. Idempotent.
    public func invalidate() {
        live.withLock { $0 = false }
    }

    public func replaceImplicitActions(_ table: ImplicitActionTable) {
        implicitActionStorage.withLock { $0 = table }
    }
}
