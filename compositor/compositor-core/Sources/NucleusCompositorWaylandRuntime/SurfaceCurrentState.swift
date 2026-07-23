import WaylandServerC
import WaylandServer
import NucleusTypes

/// The applied core content state of one wl_surface. Surface-adjacent protocol
/// state is direct `WlSurface` storage so nested mutation reaches it without a
/// forwarding copy. The pending → transaction → current ownership progression
/// remains singular for buffers, geometry, and render identity.
struct SurfaceCurrentState {
    var buffer: WaylandResourceReference?
    var bufferPixelSize = BufferPixelSize()
    var releaseCallback:
        UnsafeMutablePointer<wl_resource>?
    var bufferReleased = false

    var bufferScale: Int32 = 1
    var bufferTransform: Int32 = 0
    var opaqueRegion: RegionSnapshot?
    var inputRegion: RegionSnapshot?
    var offsetX: Int32 = 0
    var offsetY: Int32 = 0
    var committed = false

    var logicalWidth: Double = 0
    var logicalHeight: Double = 0

    var renderIOSurfaceID: UInt32 = 0
    var renderContentGeneration: UInt64 = 0
    var bufferGeneration: UInt64 = 0
}
