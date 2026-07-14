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

    public var maxX: Int32 { x &+ Int32(bitPattern: width) }
    public var maxY: Int32 { y &+ Int32(bitPattern: height) }
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
        OutputPixelRect(
            x: Int32(x(global.x).rounded(.down)),
            y: Int32(y(global.y).rounded(.down)),
            width: UInt32(max(0, (global.width * scale).rounded(.up))),
            height: UInt32(max(0, (global.height * scale).rounded(.up))))
    }
}
