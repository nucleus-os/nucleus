import WaylandServer
import WaylandServerC
import WaylandServerDispatch

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
    let buffer: WaylandResourceReference<WlBufferServer>?
    let releaseCallback: WaylandResourceReference<WlCallbackServer>?
    let offsetX: Int32
    let offsetY: Int32
    let bufferScale: Int32
    let bufferTransform: Int32
    let opaque: SurfacePendingField<RegionSnapshot>
    let input: SurfacePendingField<RegionSnapshot>
    let surfaceDamage: [WlRect]
    let bufferDamage: [WlRect]
    var frameCallbacks: [WaylandResourceReference<WlCallbackServer>]
    var presentationFeedbacks: [WaylandResourceReference<WpPresentationFeedbackServer>]
    let isInitial: Bool
    let auxViewportSource: WlFRect?
    let auxViewportSourceSet: Bool
    let auxViewportDestination: WlSize?
    let auxViewportDestinationSet: Bool
    let auxAlphaMultiplier: UInt32
    let auxAlphaMultiplierSet: Bool
    let syncAcquire: SyncPoint?
    let syncRelease: SyncPoint?
    let effects: [() -> Void]

    /// Fold a later synchronized-subsurface commit into the state already
    /// cached for its parent. Wayland cached state accumulates until the parent
    /// commit; a state-only child commit must not erase an earlier buffer,
    /// region, viewport, alpha value, callback, or synchronization point.
    func mergingCachedState(
        from previous: SurfaceTransaction
    ) -> SurfaceTransaction {
        SurfaceTransaction(
            commitID: commitID,
            bufferAttached:
                bufferAttached || previous.bufferAttached,
            buffer: bufferAttached ? buffer : previous.buffer,
            releaseCallback:
                bufferAttached
                ? releaseCallback
                : previous.releaseCallback,
            offsetX:
                bufferAttached ? offsetX : previous.offsetX,
            offsetY:
                bufferAttached ? offsetY : previous.offsetY,
            bufferScale: bufferScale,
            bufferTransform: bufferTransform,
            opaque:
                opaque.isUnchanged ? previous.opaque : opaque,
            input:
                input.isUnchanged ? previous.input : input,
            surfaceDamage:
                previous.surfaceDamage + surfaceDamage,
            bufferDamage:
                previous.bufferDamage + bufferDamage,
            frameCallbacks:
                previous.frameCallbacks + frameCallbacks,
            presentationFeedbacks:
                bufferAttached
                ? presentationFeedbacks
                : previous.presentationFeedbacks
                    + presentationFeedbacks,
            isInitial: previous.isInitial || isInitial,
            auxViewportSource:
                auxViewportSourceSet
                ? auxViewportSource
                : previous.auxViewportSource,
            auxViewportSourceSet:
                auxViewportSourceSet
                || previous.auxViewportSourceSet,
            auxViewportDestination:
                auxViewportDestinationSet
                ? auxViewportDestination
                : previous.auxViewportDestination,
            auxViewportDestinationSet:
                auxViewportDestinationSet
                || previous.auxViewportDestinationSet,
            auxAlphaMultiplier:
                auxAlphaMultiplierSet
                ? auxAlphaMultiplier
                : previous.auxAlphaMultiplier,
            auxAlphaMultiplierSet:
                auxAlphaMultiplierSet
                || previous.auxAlphaMultiplierSet,
            syncAcquire:
                bufferAttached
                ? syncAcquire
                : previous.syncAcquire,
            syncRelease:
                bufferAttached
                ? syncRelease
                : previous.syncRelease,
            effects: previous.effects + effects)
    }
}

extension SurfacePendingField {
    fileprivate var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}
