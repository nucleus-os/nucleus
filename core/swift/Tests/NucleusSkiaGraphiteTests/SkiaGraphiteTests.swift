import Testing
import NucleusSkiaGraphiteBridge

// Proves the renderer's Skia link end to end: the nucleus::skia Graphite façade
// imports under C++ interop and links against the full GN/Ninja-built Skia
// archive set (Graphite/Dawn/Vulkan + codecs + text). A real raster Skia op runs
// (no GPU/Vulkan context needed for the CPU raster path).
@Test func graphiteFacadeLinksAndRunsRasterOp() {
    let px: [UInt8] = [
        255, 0, 0, 255,   0, 255, 0, 255,
        0, 0, 255, 255,   255, 255, 0, 255,
    ]
    let img = px.withUnsafeBufferPointer { buf in
        nucleus.skia.makeRasterImageRGBA(2, 2, buf.baseAddress, buf.count)
    }
    #expect(img.isValid())
    #expect(img.width() == 2)
    #expect(img.height() == 2)
}
