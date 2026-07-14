import NucleusTypes

// `PaintCommandKind` is wire-owned (the generated discriminant enum). The
// domain `PaintCommand` is kept (its `color` defaults to opaque white and it
// has a reserved-ignoring `==`); its `.wireValue` lives in DirectBridge.swift.
public typealias PaintCommandKind = NucleusTypes.PaintCommandKind

// `Color` is the generated wire color itself (r/g/b/a: Float, Equatable,
// Sendable). The positional initializer and `opacity(_:)` are the only
// relocated conveniences; the labeled `init(r:g:b:a:)` is already memberwise.
public typealias Color = NucleusTypes.Color

extension NucleusTypes.Color {
    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
        self.init(r: r, g: g, b: b, a: a)
    }

    /// Returns this color with its alpha replaced. Mirrors
    /// `NSColor.withAlphaComponent`. Used to derive faded variants of a
    /// semantic color (e.g. an accent fill at 0.22 alpha for a status pill)
    /// without introducing per-variant tokens.
    public func opacity(_ alpha: Float) -> Color {
        Color(r, g, b, alpha)
    }
}

/// `PaintCommand` is passed only to the out-of-band paint-content
/// registration entry. Text is carried by `textLayoutHandle` (a handle to a
/// shaped Skia paragraph); there is no inline-text field.
public struct PaintCommand: Sendable, Equatable {
    public var kind: PaintCommandKind
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float
    public var radius: Float
    public var strokeWidth: Float
    public var fontSize: Float
    public var color: Color
    public var imageHandle: UInt64
    public var textLayoutHandle: UInt64

    public init(
        kind: PaintCommandKind,
        x: Float,
        y: Float,
        w: Float,
        h: Float,
        radius: Float = 0,
        strokeWidth: Float = 0,
        fontSize: Float = 0,
        color: Color = .init(1, 1, 1, 1),
        imageHandle: UInt64 = 0,
        textLayoutHandle: UInt64 = 0
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.radius = radius
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
        self.color = color
        self.imageHandle = imageHandle
        self.textLayoutHandle = textLayoutHandle
    }

    public static func == (lhs: PaintCommand, rhs: PaintCommand) -> Bool {
        lhs.kind == rhs.kind &&
            lhs.x == rhs.x &&
            lhs.y == rhs.y &&
            lhs.w == rhs.w &&
            lhs.h == rhs.h &&
            lhs.radius == rhs.radius &&
            lhs.strokeWidth == rhs.strokeWidth &&
            lhs.fontSize == rhs.fontSize &&
            lhs.color == rhs.color &&
            lhs.imageHandle == rhs.imageHandle &&
            lhs.textLayoutHandle == rhs.textLayoutHandle
    }
}
