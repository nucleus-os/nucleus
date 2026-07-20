import WaylandServerC
import WaylandServer
import NucleusTypes

/// A rectangle in fractional buffer coordinates (wp_viewport source is fixed-point).
typealias WlFRect = BufferPixelRect

/// An integer size (wp_viewport destination override, in surface-local pixels).
struct WlSize: Equatable, Sendable {
    var width: Int32
    var height: Int32
}

extension WlSize {
    var surfaceLogicalSize: SurfaceLogicalSize {
        SurfaceLogicalSize(width: Double(width), height: Double(height))
    }
}

func resolveSurfaceLogicalSize(
    pixels: BufferPixelSize,
    bufferScale: Int32,
    bufferTransform: Int32,
    viewportDestination: WlSize?
) -> SurfaceLogicalSize {
    if let viewportDestination {
        return viewportDestination.surfaceLogicalSize
    }
    let swapsAxes = bufferTransform == 1 || bufferTransform == 3
        || bufferTransform == 5 || bufferTransform == 7
    let width = swapsAxes ? pixels.height : pixels.width
    let height = swapsAxes ? pixels.width : pixels.height
    let scale = Double(max(1, bufferScale))
    return SurfaceLogicalSize(
        width: Double(width) / scale,
        height: Double(height) / scale)
}

/// Surface-adjacent protocol state resolved as part of one content transaction.
struct SurfaceAuxState: Equatable, Sendable {
    var viewportSource: WlFRect?
    var viewportDestination: WlSize?
    var syncAcquire: SyncPoint?
    var syncRelease: SyncPoint?
}

enum SurfaceAuxKind: Hashable {
    case viewport
    case fractionalScale
    case kdeBlur
    case backgroundEffect
    case syncobj
}

protocol WlSurfaceCommitObserver: AnyObject {
    func captureSurfaceCommit(
        _ surface: WlSurface,
        bufferAttached: Bool,
        attachedBufferIsNonNull: Bool,
        attachedBufferSupportsExplicitSync: Bool,
        aux: inout SurfaceAuxState,
        effects: inout [() -> Void]
    ) -> Bool
}

protocol PreferredScaleSink: AnyObject {
    func sendPreferredScale(_ scale120: UInt32)
}

struct SurfaceCommit: Sendable {
    let surfaceID: UInt32
    let commitID: UInt64
    let bufferAttached: Bool
    let bufferGeneration: UInt64
    let bufferResourceBits: UInt
    let bufferPixelSize: BufferPixelSize
    let logicalContentSize: SurfaceLogicalSize
    let bufferScale: Int32
    let bufferTransform: Int32
    let surfaceDamage: [WlRect]
    let bufferDamage: [WlRect]
    let opaqueRegion: RegionSnapshot?
    let inputRegion: RegionSnapshot?
    let isInitialCommit: Bool
    let aux: SurfaceAuxState
}

protocol SurfaceSceneDelegate: AnyObject {
    func surfaceCommitted(_ commit: SurfaceCommit)
    func surfaceDestroyed(surfaceID: UInt32, iosurfaceID: UInt32)
}

/// The sole accumulator for double-buffered core-surface state. Sticky values
/// remain after capture; per-commit resources move into exactly one immutable
/// `SurfaceTransaction`.
struct SurfacePendingState {
    var bufferAttached = false
    var buffer: WaylandResourceReference?
    var releaseCallback: UnsafeMutablePointer<wl_resource>?
    var offsetX: Int32 = 0
    var offsetY: Int32 = 0
    var surfaceDamage: [WlRect] = []
    var bufferDamage: [WlRect] = []
    var frameCallbacks: [UnsafeMutablePointer<wl_resource>] = []
    var presentationFeedbacks: [UnsafeMutablePointer<wl_resource>] = []
    var bufferScale: Int32 = 1
    var bufferTransform: Int32 = 0
    var opaque: SurfacePendingField<RegionSnapshot> = .unchanged
    var input: SurfacePendingField<RegionSnapshot> = .unchanged
    var viewportSource: WlFRect?
    var viewportSourceSet = false
    var viewportDestination: WlSize?
    var viewportDestinationSet = false

    mutating func capture(
        commitID: UInt64,
        isInitial: Bool,
        syncAcquire: SyncPoint?,
        syncRelease: SyncPoint?,
        effects: [() -> Void]
    ) -> SurfaceTransaction {
        let transaction = SurfaceTransaction(
            commitID: commitID,
            bufferAttached: bufferAttached,
            buffer: buffer,
            releaseCallback: releaseCallback,
            offsetX: offsetX,
            offsetY: offsetY,
            bufferScale: bufferScale,
            bufferTransform: bufferTransform,
            opaque: opaque,
            input: input,
            surfaceDamage: surfaceDamage,
            bufferDamage: bufferDamage,
            frameCallbacks: frameCallbacks,
            presentationFeedbacks: presentationFeedbacks,
            isInitial: isInitial,
            auxViewportSource: viewportSource,
            auxViewportSourceSet: viewportSourceSet,
            auxViewportDestination: viewportDestination,
            auxViewportDestinationSet: viewportDestinationSet,
            syncAcquire: syncAcquire,
            syncRelease: syncRelease,
            effects: effects)

        bufferAttached = false
        buffer = nil
        releaseCallback = nil
        offsetX = 0
        offsetY = 0
        opaque = .unchanged
        input = .unchanged
        surfaceDamage.removeAll(keepingCapacity: true)
        bufferDamage.removeAll(keepingCapacity: true)
        frameCallbacks.removeAll(keepingCapacity: true)
        presentationFeedbacks.removeAll(keepingCapacity: true)
        viewportSourceSet = false
        viewportDestinationSet = false
        return transaction
    }
}
