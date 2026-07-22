// accumulator (or any surface) back into a host buffer, then convert to the
// client's pixel layout. The Graphite-native analog of ScreencopyGpu /
// ScreenshotPipeline's pixel-format handling. GPU readback belongs to
// RenderCore's bounded asynchronous capture queue; this file is pure conversion.

/// The screencopy/screenshot destination pixel layout (the 8-bit subset the
/// wl_shm / DRM XRGB paths use; 10-bit HDR is a future addition). Mirrors
/// `ScreenshotPixelFormat`.
enum ScreenshotPixelFormat {
    case rgba8888
    case bgra8888
}

enum Screenshot {
    /// Convert tightly-packed RGBA8888-premultiplied rows to `format`. `bgra8888`
    /// swaps the R and B channels (the wl_shm XRGB8888 / DRM layout).
    static func convert(rgba: [UInt8], to format: ScreenshotPixelFormat) -> [UInt8] {
        switch format {
        case .rgba8888:
            return rgba
        case .bgra8888:
            var out = rgba
            var i = 0
            while i + 3 < out.count {
                out.swapAt(i, i + 2)  // R ↔ B
                i += 4
            }
            return out
        }
    }
}
