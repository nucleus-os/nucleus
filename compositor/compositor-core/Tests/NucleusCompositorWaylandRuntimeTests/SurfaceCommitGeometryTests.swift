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

    @Test func implicitXdgWindowGeometryUsesTheCommittedSurfaceExtent() {
        #expect(xdgCommittedContentSize(
            windowGeometry: nil,
            surfaceLogicalWidth: 1280,
            surfaceLogicalHeight: 720
        ) == XdgCommittedContentSize(width: 1280, height: 720))
    }

    @Test func explicitXdgWindowGeometrySelectsTheVisibleSubrectangle() {
        #expect(xdgCommittedContentSize(
            windowGeometry: WlRect(x: 8, y: 12, width: 960, height: 540),
            surfaceLogicalWidth: 1280,
            surfaceLogicalHeight: 720
        ) == XdgCommittedContentSize(width: 960, height: 540))
    }
}
