#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import NucleusTypes

/// A `CGPath`-shaped geometry value built from move, line, curve, and arc
/// segments. It contains no rendering state; the draw call supplies paint.
///
/// Coordinates remain `Double` on the geometry plane and narrow to `Float`
/// exactly once when a paint command is encoded.
public struct Path: Sendable, Equatable {
    package private(set) var verbs: [PaintPathVerb] = []
    package private(set) var points: [Double] = []
    /// Even-odd rather than the default winding fill rule.
    public var usesEvenOddFillRule: Bool = false

    public init() {}

    public var isEmpty: Bool { verbs.isEmpty }

    /// The point a `close` returns to, and the origin an implicit segment
    /// starts from, matching `CGPath` current-subpath behavior.
    public private(set) var currentPoint: Point?
    private var subpathStart: Point?

    public mutating func move(to point: Point) {
        guard point.isFinite else { return }
        verbs.append(.move)
        append(point)
        currentPoint = point
        subpathStart = point
    }

    public mutating func addLine(to point: Point) {
        guard point.isFinite else { return }
        ensureStart(point)
        verbs.append(.line)
        append(point)
        currentPoint = point
    }

    public mutating func addQuadCurve(to point: Point, control: Point) {
        guard point.isFinite, control.isFinite else { return }
        ensureStart(control)
        verbs.append(.quad)
        append(control)
        append(point)
        currentPoint = point
    }

    public mutating func addCurve(to point: Point, control1: Point, control2: Point) {
        guard point.isFinite, control1.isFinite, control2.isFinite else { return }
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
        guard rect.isFinite, !rect.isEmpty, start.isFinite, sweep.isFinite,
              sweep != 0
        else { return }

        let startPoint = point(on: rect, degrees: start)
        let endPoint: Point
        if abs(sweep) >= 360 {
            // The renderer defines an over-full sweep as one complete ellipse.
            // Preserve the authored start as the contour's terminal point.
            endPoint = startPoint
        } else {
            endPoint = point(on: rect, degrees: start + sweep)
        }

        if let currentPoint {
            if !approximatelyEqual(currentPoint, startPoint) {
                addLine(to: startPoint)
            }
        } else {
            // An arc opens its subpath at the real arc start, not at the oval's
            // bounding-box origin.
            move(to: startPoint)
        }

        verbs.append(.arc)
        points.append(rect.origin.x)
        points.append(rect.origin.y)
        points.append(rect.size.width)
        points.append(rect.size.height)
        points.append(start)
        points.append(sweep)
        currentPoint = endPoint
    }

    public mutating func close() {
        guard !verbs.isEmpty else { return }
        verbs.append(.close)
        currentPoint = subpathStart
    }

    // MARK: - Shape conveniences

    public mutating func addRect(_ rect: Rect) {
        guard rect.isFinite, !rect.isEmpty else { return }
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
        guard rect.isFinite, !rect.isEmpty, radius.isFinite else { return }
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
        guard rect.isFinite, !rect.isEmpty else { return }
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
        points.append(point.x)
        points.append(point.y)
    }

    private func point(on rect: Rect, degrees: Double) -> Point {
        let radians = degrees * .pi / 180
        let radiusX = rect.size.width / 2
        let radiusY = rect.size.height / 2
        return Point(
            x: rect.origin.x + radiusX + cos(radians) * radiusX,
            y: rect.origin.y + radiusY + sin(radians) * radiusY)
    }

    private func approximatelyEqual(_ lhs: Point, _ rhs: Point) -> Bool {
        let scale = max(
            1, abs(lhs.x), abs(lhs.y), abs(rhs.x), abs(rhs.y))
        let tolerance = scale * 1e-12
        return abs(lhs.x - rhs.x) <= tolerance &&
            abs(lhs.y - rhs.y) <= tolerance
    }
}
