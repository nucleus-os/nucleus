/// An integer rectangle used by compositor coverage and damage regions.
/// Coordinates are half-open: `[x, x + width) × [y, y + height)`.
public struct RegionRect: Equatable, Hashable, Sendable {
    public var x: Int32
    public var y: Int32
    public var width: Int32
    public var height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    fileprivate var minX: Int64 { Int64(x) }
    fileprivate var minY: Int64 { Int64(y) }
    fileprivate var maxX: Int64 { Int64(x) + Int64(width) }
    fileprivate var maxY: Int64 { Int64(y) + Int64(height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// Exact canonical coverage represented by disjoint, maximally coalesced integer
/// rectangles. All boolean operations normalize their result, so consumers never
/// need to replay or reinterpret a mutation history.
public struct Region: Equatable, Sendable {
    public private(set) var rectangles: [RegionRect]

    public init() {
        rectangles = []
    }

    public init(_ rect: RegionRect) {
        rectangles = rect.isEmpty ? [] : [rect]
    }

    public init(rectangles: [RegionRect]) {
        self = rectangles.reduce(into: Region()) { result, rect in
            result.formUnion(rect)
        }
    }

    public var isEmpty: Bool { rectangles.isEmpty }
    public var rectangleCount: Int { rectangles.count }

    public var bounds: RegionRect? {
        guard let first = rectangles.first else { return nil }
        var minX = first.minX
        var minY = first.minY
        var maxX = first.maxX
        var maxY = first.maxY
        for rect in rectangles.dropFirst() {
            minX = Swift.min(minX, rect.minX)
            minY = Swift.min(minY, rect.minY)
            maxX = Swift.max(maxX, rect.maxX)
            maxY = Swift.max(maxY, rect.maxY)
        }
        return Self.rect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    public func contains(x: Double, y: Double) -> Bool {
        rectangles.contains { rect in
            x >= Double(rect.minX) && x < Double(rect.maxX)
                && y >= Double(rect.minY) && y < Double(rect.maxY)
        }
    }

    public func contains(_ rect: RegionRect) -> Bool {
        guard !rect.isEmpty else { return true }
        return Region(rect).subtracting(self).isEmpty
    }

    public mutating func formUnion(_ rect: RegionRect) {
        guard !rect.isEmpty else { return }
        self = Self.combine(self, Region(rect), where: { $0 || $1 })
    }

    public mutating func formUnion(_ other: Region) {
        self = Self.combine(self, other, where: { $0 || $1 })
    }

    public func union(_ other: Region) -> Region {
        Self.combine(self, other, where: { $0 || $1 })
    }

    public mutating func subtract(_ rect: RegionRect) {
        guard !rect.isEmpty else { return }
        self = subtracting(Region(rect))
    }

    public func subtracting(_ other: Region) -> Region {
        Self.combine(self, other, where: { $0 && !$1 })
    }

    public func intersection(_ other: Region) -> Region {
        Self.combine(self, other, where: { $0 && $1 })
    }

    /// Returns exact coverage unless it exceeds the caller's storage budget, in
    /// which case the conservative bounding rectangle is returned. This is suitable
    /// for damage, where overdraw is valid; input and opaque regions stay exact.
    public func conservative(maxRectangles: Int) -> Region {
        guard rectangles.count > maxRectangles, let bounds else { return self }
        return Region(bounds)
    }

    private static func combine(
        _ lhs: Region,
        _ rhs: Region,
        where include: (Bool, Bool) -> Bool
    ) -> Region {
        let all = lhs.rectangles + rhs.rectangles
        guard !all.isEmpty else { return Region() }
        let ys = Array(Set(all.flatMap { [$0.minY, $0.maxY] })).sorted()
        let xs = Array(Set(all.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard ys.count > 1, xs.count > 1 else { return Region() }

        struct Span: Hashable { var minX: Int64; var maxX: Int64 }
        var output: [RegionRect] = []
        var active: [Span: Int] = [:]

        for yIndex in 0..<(ys.count - 1) {
            let minY = ys[yIndex]
            let maxY = ys[yIndex + 1]
            var spans: [Span] = []
            var spanStart: Int64?

            for xIndex in 0..<(xs.count - 1) {
                let minX = xs[xIndex]
                let maxX = xs[xIndex + 1]
                let inLHS = covers(lhs.rectangles, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
                let inRHS = covers(rhs.rectangles, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
                if include(inLHS, inRHS) {
                    spanStart = spanStart ?? minX
                } else if let start = spanStart {
                    spans.append(Span(minX: start, maxX: minX))
                    spanStart = nil
                }
            }
            if let start = spanStart, let maxX = xs.last {
                spans.append(Span(minX: start, maxX: maxX))
            }

            var nextActive: [Span: Int] = [:]
            for span in spans {
                if let index = active[span], output[index].maxY == minY,
                    let extended = rect(minX: span.minX, minY: output[index].minY, maxX: span.maxX, maxY: maxY)
                {
                    output[index] = extended
                    nextActive[span] = index
                } else if let newRect = rect(minX: span.minX, minY: minY, maxX: span.maxX, maxY: maxY) {
                    output.append(newRect)
                    nextActive[span] = output.count - 1
                }
            }
            active = nextActive
        }
        var result = Region()
        result.rectangles = output
        return result
    }

    private static func covers(
        _ rectangles: [RegionRect], minX: Int64, minY: Int64, maxX: Int64, maxY: Int64
    ) -> Bool {
        rectangles.contains {
            $0.minX <= minX && $0.minY <= minY && $0.maxX >= maxX && $0.maxY >= maxY
        }
    }

    private static func rect(minX: Int64, minY: Int64, maxX: Int64, maxY: Int64) -> RegionRect? {
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0,
            minX >= Int64(Int32.min), minX <= Int64(Int32.max),
            minY >= Int64(Int32.min), minY <= Int64(Int32.max),
            width <= Int64(Int32.max), height <= Int64(Int32.max)
        else { return nil }
        return RegionRect(x: Int32(minX), y: Int32(minY), width: Int32(width), height: Int32(height))
    }
}
