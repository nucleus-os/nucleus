import Testing
import NucleusTypes
@testable import NucleusCompositorWaylandRuntime

@Suite struct SurfaceCommitGeometryTests {
    @Test func viewportDestinationAndBufferTransformResolveOnceAtCommit() {
        let pixels = BufferPixelSize(width: 2400, height: 1600)
        #expect(resolveSurfaceLogicalSize(
            pixels: pixels, bufferScale: 2, bufferTransform: 0,
            viewportDestination: nil) == SurfaceLogicalSize(width: 1200, height: 800))
        #expect(resolveSurfaceLogicalSize(
            pixels: pixels, bufferScale: 2, bufferTransform: 1,
            viewportDestination: nil) == SurfaceLogicalSize(width: 800, height: 1200))
        #expect(resolveSurfaceLogicalSize(
            pixels: pixels, bufferScale: 2, bufferTransform: 1,
            viewportDestination: WlSize(width: 1000, height: 700))
            == SurfaceLogicalSize(width: 1000, height: 700))
    }
}
