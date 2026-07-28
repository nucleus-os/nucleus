/// Coordinate-space vocabulary shared by protocol ingestion, scene authoring,
/// input, and presentation. These deliberately do not inter-convert implicitly:
/// every boundary must name the transform it applies.

public struct BufferPixelSize: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32

    public init(width: UInt32 = 0, height: UInt32 = 0) {
        self.width = width
        self.height = height
    }
}

/// Buffer-local pixels. Floating point is required by wp_viewport source crops.
public struct BufferPixelRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SurfaceLogicalSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double = 0, height: Double = 0) {
        self.width = width
        self.height = height
    }
}

public struct SurfaceLogicalRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

public struct GlobalLogicalRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

public struct OutputPixelSize: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32

    public init(width: UInt32 = 0, height: UInt32 = 0) {
        self.width = width
        self.height = height
    }
}

public struct OutputPixelRect: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
    public var width: UInt32
    public var height: UInt32

    public init(x: Int32 = 0, y: Int32 = 0, width: UInt32 = 0, height: UInt32 = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int64 { Int64(x) + Int64(width) }
    public var maxY: Int64 { Int64(y) + Int64(height) }
    public var isEmpty: Bool { width == 0 || height == 0 }
}

/// The sole global-logical → output-pixel projection. The output origin and
/// fractional scale travel together so callers cannot apply only half of it.
public struct GlobalToOutputTransform: Equatable, Sendable {
    public var outputLogicalOriginX: Double
    public var outputLogicalOriginY: Double
    public var scale: Double

    public init(outputLogicalOriginX: Double, outputLogicalOriginY: Double, scale: Double) {
        self.outputLogicalOriginX = outputLogicalOriginX
        self.outputLogicalOriginY = outputLogicalOriginY
        self.scale = scale
    }

    public func x(_ globalX: Double) -> Double {
        (globalX - outputLogicalOriginX) * scale
    }

    public func y(_ globalY: Double) -> Double {
        (globalY - outputLogicalOriginY) * scale
    }

    public func rect(_ global: GlobalLogicalRect) -> OutputPixelRect {
        guard outputLogicalOriginX.isFinite,
            outputLogicalOriginY.isFinite,
            scale.isFinite,
            scale > 0,
            global.x.isFinite,
            global.y.isFinite,
            global.width.isFinite,
            global.height.isFinite
        else { return OutputPixelRect() }

        return OutputPixelRect(
            x: saturatedInt32(x(global.x), rounding: .down),
            y: saturatedInt32(y(global.y), rounding: .down),
            width: saturatedExtent(global.width * scale),
            height: saturatedExtent(global.height * scale))
    }
}

private func saturatedInt32(
    _ value: Double,
    rounding rule: FloatingPointRoundingRule
) -> Int32 {
    guard !value.isNaN else { return 0 }
    let rounded = value.rounded(rule)
    if rounded <= Double(Int32.min) { return .min }
    if rounded >= Double(Int32.max) { return .max }
    return Int32(rounded)
}

private func saturatedExtent(_ value: Double) -> UInt32 {
    guard value.isFinite, value > 0 else {
        return value == .infinity ? .max : 0
    }
    let rounded = value.rounded(.up)
    if rounded >= Double(UInt32.max) { return .max }
    return UInt32(rounded)
}
