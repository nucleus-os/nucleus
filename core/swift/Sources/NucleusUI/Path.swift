import NucleusTypes

/// A geometry path built from move/line/curve/arc segments. Mirrors `CGPath`:
/// a value type accumulating verbs and points, with no rendering state of its
/// own — how it is painted is decided at the draw call.
///
/// Coordinates are `Double` on the geometry plane and narrow to `Float` at the
/// paint-command boundary, per the framework's Float/Double split.
public struct Path: Sendable, Equatable {
    package private(set) var verbs: [PaintPathVerb] = []
    package private(set) var points: [Float] = []
    /// Even-odd rather than the default winding fill rule.
    public var usesEvenOddFillRule: Bool = false

    public init() {}

    public var isEmpty: Bool { verbs.isEmpty }

    /// The point a `close` returns to, and the origin an implicit segment
    /// starts from. Mirrors `CGPath`'s current-subpath tracking.
    public private(set) var currentPoint: Point?
    private var subpathStart: Point?

    public mutating func move(to point: Point) {
        verbs.append(.move)
        append(point)
        currentPoint = point
        subpathStart = point
    }

    public mutating func addLine(to point: Point) {
        ensureStart(point)
        verbs.append(.line)
        append(point)
        currentPoint = point
    }

    public mutating func addQuadCurve(to point: Point, control: Point) {
        ensureStart(control)
        verbs.append(.quad)
        append(control)
        append(point)
        currentPoint = point
    }

    public mutating func addCurve(to point: Point, control1: Point, control2: Point) {
        ensureStart(control1)
        verbs.append(.cubic)
        append(control1)
        append(control2)
        append(point)
        currentPoint = point
    }

    /// Append an arc bounded by `rect`, sweeping `sweep` degrees from `start`
    /// degrees (0° is the positive x axis). An arc is a verb rather than a
    /// separate primitive, so a spinner or progress ring is an ordinary
    /// stroked path.
    public mutating func addArc(in rect: Rect, start: Double, sweep: Double) {
        if currentPoint == nil {
            // An arc may open a subpath; anchor it so `close` has a target.
            let origin = Point(x: rect.origin.x, y: rect.origin.y)
            currentPoint = origin
            subpathStart = origin
        }
        verbs.append(.arc)
        points.append(Float(rect.origin.x))
        points.append(Float(rect.origin.y))
        points.append(Float(rect.size.width))
        points.append(Float(rect.size.height))
        points.append(Float(start))
        points.append(Float(sweep))
    }

    public mutating func close() {
        guard !verbs.isEmpty else { return }
        verbs.append(.close)
        currentPoint = subpathStart
    }

    // MARK: - Shape conveniences

    public mutating func addRect(_ rect: Rect) {
        move(to: Point(x: rect.origin.x, y: rect.origin.y))
        addLine(to: Point(x: rect.origin.x + rect.size.width, y: rect.origin.y))
        addLine(to: Point(
            x: rect.origin.x + rect.size.width, y: rect.origin.y + rect.size.height))
        addLine(to: Point(x: rect.origin.x, y: rect.origin.y + rect.size.height))
        close()
    }

    /// A rounded rectangle built from four arcs and four lines. `radius` is
    /// clamped to half the shorter side, matching how a rounded rect degrades
    /// to a capsule and then to a circle.
    public mutating func addRoundedRect(_ rect: Rect, radius: Double) {
        let r = min(max(0, radius), min(rect.size.width, rect.size.height) / 2)
        guard r > 0 else {
            addRect(rect)
            return
        }
        let x = rect.origin.x, y = rect.origin.y
        let w = rect.size.width, h = rect.size.height
        let d = r * 2

        move(to: Point(x: x + r, y: y))
        addLine(to: Point(x: x + w - r, y: y))
        addArc(in: Rect(x: x + w - d, y: y, width: d, height: d), start: -90, sweep: 90)
        addLine(to: Point(x: x + w, y: y + h - r))
        addArc(in: Rect(x: x + w - d, y: y + h - d, width: d, height: d), start: 0, sweep: 90)
        addLine(to: Point(x: x + r, y: y + h))
        addArc(in: Rect(x: x, y: y + h - d, width: d, height: d), start: 90, sweep: 90)
        addLine(to: Point(x: x, y: y + r))
        addArc(in: Rect(x: x, y: y, width: d, height: d), start: 180, sweep: 90)
        close()
    }

    public mutating func addEllipse(in rect: Rect) {
        addArc(in: rect, start: 0, sweep: 360)
        close()
    }

    // MARK: -

    /// A line/curve without a preceding `move` implicitly opens the subpath,
    /// matching `CGPath`. Without this a stray `addLine` would emit points no
    /// verb consumes, and the payload decoder would reject the whole draw.
    private mutating func ensureStart(_ fallback: Point) {
        guard currentPoint == nil else { return }
        move(to: fallback)
    }

    private mutating func append(_ point: Point) {
        points.append(Float(point.x))
        points.append(Float(point.y))
    }
}
