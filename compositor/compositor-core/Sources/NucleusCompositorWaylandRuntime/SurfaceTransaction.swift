import WaylandServerC
import WaylandServer

/// One field's double-buffered mutation. `set(nil)` is an explicit clear.
enum SurfacePendingField<T> {
    case unchanged
    case set(T?)
}

/// One immutable capture of every core and adjacent state mutation accepted by
/// `wl_surface.commit`. It can be applied immediately or cached as one unit by a
/// synchronized subsurface.
struct SurfaceTransaction {
    let commitID: UInt64
    let bufferAttached: Bool
    let buffer: WaylandResourceReference?
    let releaseCallback: UnsafeMutablePointer<wl_resource>?
    let offsetX: Int32
    let offsetY: Int32
    let bufferScale: Int32
    let bufferTransform: Int32
    let opaque: SurfacePendingField<RegionSnapshot>
    let input: SurfacePendingField<RegionSnapshot>
    let surfaceDamage: [WlRect]
    let bufferDamage: [WlRect]
    var frameCallbacks: [UnsafeMutablePointer<wl_resource>]
    var presentationFeedbacks: [UnsafeMutablePointer<wl_resource>]
    let isInitial: Bool
    let auxViewportSource: WlFRect?
    let auxViewportSourceSet: Bool
    let auxViewportDestination: WlSize?
    let auxViewportDestinationSet: Bool
    let syncAcquire: SyncPoint?
    let syncRelease: SyncPoint?
    let effects: [() -> Void]
}
