/// The logical coordinate spaces that meet at NucleusUI host boundaries.
///
/// NucleusUI uses a top-left origin with y increasing downward in every logical
/// space. Public geometry is `Double`. Only `backing` is pixel-scaled.
public enum CoordinateSpace: Sendable, Equatable {
    /// Global logical space used to place windows in one published scene.
    case scene
    /// A window's content space, beginning at `(0, 0)`.
    case window(WindowID)
    /// A retained view's bounds coordinate system.
    case view(ViewID)
    /// A Wayland or platform presentation surface's local logical space.
    case surface
    /// Physical backing pixels for one surface.
    case backing
    /// Logical coordinates in the host's output arrangement.
    case output
}

/// Stable host identity for one platform presentation surface.
public struct PresentationSurfaceID: RawRepresentable, Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "PresentationSurfaceID.zero is reserved")
        self.rawValue = rawValue
    }
}

/// The explicit association between a Nucleus window and the platform surface
/// currently presenting it.
public struct WindowSurfaceAssociation: Sendable, Equatable {
    public var surfaceID: PresentationSurfaceID
    public var transform: WindowSurfaceTransform

    public init(
        surfaceID: PresentationSurfaceID,
        transform: WindowSurfaceTransform = WindowSurfaceTransform()
    ) {
        self.surfaceID = surfaceID
        self.transform = transform
    }
}

/// Explicit conversion boundary between one window and one presentation
/// surface.
///
/// `windowOriginInSurface` accounts for platform chrome or an embedder viewport.
/// `surfaceOriginInOutput` places the surface in the output arrangement.
/// Backing scale is applied only by the backing conversion methods.
public struct WindowSurfaceTransform: Sendable, Equatable {
    public var windowOriginInSurface: Point
    public var surfaceOriginInOutput: Point
    public var backingScaleFactor: BackingScaleFactor

    public init(
        windowOriginInSurface: Point = .zero,
        surfaceOriginInOutput: Point = .zero,
        backingScaleFactor: BackingScaleFactor = .one
    ) {
        self.windowOriginInSurface = windowOriginInSurface
        self.surfaceOriginInOutput = surfaceOriginInOutput
        self.backingScaleFactor = backingScaleFactor
    }

    public func surfacePoint(fromWindow point: Point) -> Point {
        Point(
            x: point.x + windowOriginInSurface.x,
            y: point.y + windowOriginInSurface.y
        )
    }

    public func windowPoint(fromSurface point: Point) -> Point {
        Point(
            x: point.x - windowOriginInSurface.x,
            y: point.y - windowOriginInSurface.y
        )
    }

    public func outputPoint(fromSurface point: Point) -> Point {
        Point(
            x: point.x + surfaceOriginInOutput.x,
            y: point.y + surfaceOriginInOutput.y
        )
    }

    public func surfacePoint(fromOutput point: Point) -> Point {
        Point(
            x: point.x - surfaceOriginInOutput.x,
            y: point.y - surfaceOriginInOutput.y
        )
    }

    public func backingPoint(fromSurface point: Point) -> Point {
        backingScaleFactor.backingPixels(fromPoints: point)
    }

    public func surfacePoint(fromBacking point: Point) -> Point {
        backingScaleFactor.points(fromBackingPixels: point)
    }

    public func surfaceRect(fromWindow rect: Rect) -> Rect {
        Rect(origin: surfacePoint(fromWindow: rect.origin), size: rect.size)
    }

    public func windowRect(fromSurface rect: Rect) -> Rect {
        Rect(origin: windowPoint(fromSurface: rect.origin), size: rect.size)
    }

    public func backingRect(fromSurface rect: Rect) -> Rect {
        backingScaleFactor.backingPixels(fromPoints: rect)
    }

    public func surfaceRect(fromBacking rect: Rect) -> Rect {
        backingScaleFactor.points(fromBackingPixels: rect)
    }
}
