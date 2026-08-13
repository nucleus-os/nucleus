import NucleusSkiaGraphiteBridge

/// Test-only safe view over an immutable C++ raster image. The wrapper never
/// exposes the RAII value, and readback validates the live byte span it lends.
@safe struct RasterFixtureImage {
    private let image: nucleus.skia.RasterImage

    init(_ image: nucleus.skia.RasterImage) {
        self.image = image
    }

    var isValid: Bool { image.isValid() }
    var width: Int32 { image.width() }
    var height: Int32 { image.height() }

    func readPixelsRGBA(into bytes: inout [UInt8], rowBytes: Int32) -> Bool {
        bytes.withUnsafeMutableBufferPointer {
            unsafe image.readPixelsRGBA($0.baseAddress, $0.count, rowBytes)
        }
    }

    func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let pixelWidth = Int(width)
        var bytes = [UInt8](
            repeating: 0,
            count: pixelWidth * Int(height) * 4)
        precondition(
            readPixelsRGBA(
                into: &bytes,
                rowBytes: Int32(pixelWidth * 4)))
        let index = (y * pixelWidth + x) * 4
        return (
            bytes[index],
            bytes[index + 1],
            bytes[index + 2],
            bytes[index + 3]
        )
    }
}

/// Test-only owned path; its C++ value is immutable after construction.
@safe struct RasterFixturePath {
    fileprivate let value: nucleus.skia.Path

    init(_ value: nucleus.skia.Path) {
        self.value = value
    }

    func isValid() -> Bool { value.isValid() }
}

/// Test-only owned shader; its C++ value is immutable after construction.
@safe struct RasterFixtureShader {
    fileprivate let value: nucleus.skia.Shader

    init(_ value: nucleus.skia.Shader) {
        unsafe self.value = unsafe value
    }

    func isValid() -> Bool { unsafe value.isValid() }
}

/// Test-only compiled effect whose methods return safe shader wrappers.
@safe struct RasterFixtureEffect {
    private let value: nucleus.skia.RuntimeEffect

    init(_ source: String) {
        unsafe value = nucleus.skia.makeRuntimeEffect(source)
    }

    func isValid() -> Bool { value.isValid() }

    func makeShader(_ uniforms: [Float]) -> RasterFixtureShader {
        uniforms.withUnsafeBufferPointer {
            unsafe RasterFixtureShader(
                value.makeShader($0.baseAddress, $0.count))
        }
    }
}

/// Canvas access is confined to the synchronous raster-render closure.
@safe struct RasterFixtureCanvas {
    private let value: nucleus.skia.Canvas

    init(_ value: nucleus.skia.Canvas) {
        unsafe self.value = value
    }

    func drawPath(_ path: RasterFixturePath, _ paint: nucleus.skia.Paint) {
        unsafe value.drawPath(path.value, paint)
    }

    func drawPathWithShader(
        _ path: RasterFixturePath,
        _ shader: RasterFixtureShader,
        _ paint: nucleus.skia.Paint
    ) {
        unsafe value.drawPathWithShader(path.value, shader.value, paint)
    }

    func drawRRect(
        _ rect: nucleus.skia.RectF,
        _ radii: nucleus.skia.RRectRadii,
        _ paint: nucleus.skia.Paint
    ) {
        unsafe value.drawRRect(rect, radii, paint)
    }

    func clipPath(_ path: RasterFixturePath, _ antialias: Bool) {
        unsafe value.clipPath(path.value, antialias)
    }

    func concat(_ matrix: [Float]) {
        precondition(matrix.count == 9)
        matrix.withUnsafeBufferPointer {
            unsafe value.concat($0.baseAddress)
        }
    }
}

func makeRasterFixturePath(
    _ verbs: [UInt8],
    _ points: [Float],
    evenOdd: Bool = false
) -> RasterFixturePath {
    verbs.withUnsafeBufferPointer { verbs in
        points.withUnsafeBufferPointer { points in
            unsafe RasterFixturePath(
                nucleus.skia.makePath(
                    verbs.baseAddress,
                    verbs.count,
                    points.baseAddress,
                    points.count,
                    evenOdd))
        }
    }
}

func makeLinearGradientFixture(
    colors: [nucleus.skia.Color],
    x0: Float,
    y0: Float,
    x1: Float,
    y1: Float
) -> RasterFixtureShader {
    colors.withUnsafeBufferPointer {
        unsafe RasterFixtureShader(
            nucleus.skia.makeLinearGradient(
                x0, y0, x1, y1, $0.baseAddress, nil, $0.count, .clamp))
    }
}

func makeSweepGradientFixture(
    colors: [nucleus.skia.Color],
    centerX: Float,
    centerY: Float,
    start: Float,
    end: Float
) -> RasterFixtureShader {
    colors.withUnsafeBufferPointer {
        unsafe RasterFixtureShader(
            nucleus.skia.makeSweepGradient(
                centerX, centerY, start, end,
                $0.baseAddress, nil, $0.count, .clamp))
    }
}

func renderRasterFixture(
    width: Int32,
    height: Int32,
    _ body: (RasterFixtureCanvas) -> Void
) -> [UInt8] {
    let surface = unsafe nucleus.skia.makeRasterSurface(width, height)
    guard unsafe surface.isValid() else { return [] }
    let canvas = unsafe surface.getCanvas()
    var clear = nucleus.skia.Color()
    clear.a = 1
    unsafe canvas.clear(clear)
    body(unsafe RasterFixtureCanvas(canvas))

    var pixels = [UInt8](repeating: 0, count: Int(width * height) * 4)
    let ok = pixels.withUnsafeMutableBufferPointer {
        unsafe surface.readPixelsRGBA(
            $0.baseAddress, $0.count, Int32(width * 4))
    }
    return ok ? pixels : []
}
