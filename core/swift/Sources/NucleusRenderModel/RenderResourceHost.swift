// Phase 10c.3 cutover — the process-global Swift resource host.
//
// Aggregates the GPU-independent stores the layers resource-host conformers
// (paint/image/snapshot/implicit-action registrars + lifecycles) write and the
// renderer reads at frame time. One process-global instance so a registration
// from any layers context and the renderer's per-frame read share one host.
//
// `@unchecked Sendable`: the compositor runs single-threaded on its main loop
// (the lifecycle protocols are `Sendable` and may be invoked from a value's
// `deinit`, but in this runtime that still happens on the compositor thread), so
// the contained reference-type stores are accessed without further locking.
public final class SwiftResourceHost: @unchecked Sendable {
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

    /// Resident implicit-action templates (the layers curve set). Replaced
    /// wholesale by the implicit-action registrar.
    public var implicitActions = ImplicitActionTable()

    public init() {}
}
