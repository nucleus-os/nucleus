/// Which side of its anchor a popup prefers to sit on.
public enum PopupEdge: Sendable, Equatable {
    case above
    case below
    case leading
    case trailing

    /// The side to try when the preferred one does not fit. Flipping across the
    /// anchor keeps the popup attached to the thing it describes; sliding it
    /// along the same edge would eventually detach it entirely.
    var opposite: PopupEdge {
        switch self {
        case .above: return .below
        case .below: return .above
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }

    var isVertical: Bool { self == .above || self == .below }
}

/// Where a popup ended up, and on which side it actually landed.
public struct PopupPlacement: Sendable, Equatable {
    public var frame: Rect
    /// The edge finally used, which is the preferred one unless it did not fit.
    /// A caller drawing an arrow needs to know which way it points.
    public var edge: PopupEdge

    public init(frame: Rect, edge: PopupEdge) {
        self.frame = frame
        self.edge = edge
    }
}

/// Place a popup of `size` against `anchor`, inside `bounds`.
///
/// Three rules, in order. Sit on the preferred edge. If that overflows, flip to
/// the opposite edge — but only if the flip actually has more room, since
/// flipping into a worse position helps nobody. Then slide along the
/// perpendicular axis to stay inside, because a popup that runs off the side of
/// the screen is worse than one that is not perfectly centred on its anchor.
///
/// Pure: no window, no scene, no view. Placement is the part worth testing and
/// the part most likely to be wrong at a screen edge, which is exactly where it
/// is hardest to reproduce by hand.
public func resolvePopupPlacement(
    anchor: Rect,
    size: Size,
    preferring edge: PopupEdge,
    within bounds: Rect,
    gap: Double = 6,
    margin: Double = 4
) -> PopupPlacement {
    let chosen = fittingEdge(
        anchor: anchor, size: size, preferring: edge, within: bounds, gap: gap)

    var origin = originFor(chosen, anchor: anchor, size: size, gap: gap)

    // Slide along the perpendicular axis to stay inside.
    if chosen.isVertical {
        origin.x = clamp(
            origin.x,
            low: bounds.origin.x + margin,
            high: bounds.origin.x + bounds.size.width - size.width - margin)
    } else {
        origin.y = clamp(
            origin.y,
            low: bounds.origin.y + margin,
            high: bounds.origin.y + bounds.size.height - size.height - margin)
    }

    return PopupPlacement(frame: Rect(origin: origin, size: size), edge: chosen)
}

/// The preferred edge unless the opposite one has strictly more room.
private func fittingEdge(
    anchor: Rect, size: Size, preferring edge: PopupEdge, within bounds: Rect,
    gap: Double
) -> PopupEdge {
    let preferred = space(on: edge, anchor: anchor, within: bounds)
    let needed = edge.isVertical ? size.height + gap : size.width + gap
    if preferred >= needed { return edge }

    let alternative = space(on: edge.opposite, anchor: anchor, within: bounds)
    return alternative > preferred ? edge.opposite : edge
}

/// The room between the anchor and the edge of `bounds` on a given side.
private func space(on edge: PopupEdge, anchor: Rect, within bounds: Rect) -> Double {
    switch edge {
    case .above:
        return anchor.origin.y - bounds.origin.y
    case .below:
        return (bounds.origin.y + bounds.size.height)
            - (anchor.origin.y + anchor.size.height)
    case .leading:
        return anchor.origin.x - bounds.origin.x
    case .trailing:
        return (bounds.origin.x + bounds.size.width)
            - (anchor.origin.x + anchor.size.width)
    }
}

/// Centred on the anchor along the perpendicular axis, offset by `gap` along
/// the chosen one.
private func originFor(
    _ edge: PopupEdge, anchor: Rect, size: Size, gap: Double
) -> Point {
    let centreX = anchor.origin.x + (anchor.size.width - size.width) / 2
    let centreY = anchor.origin.y + (anchor.size.height - size.height) / 2

    switch edge {
    case .above:
        return Point(x: centreX, y: anchor.origin.y - size.height - gap)
    case .below:
        return Point(x: centreX, y: anchor.origin.y + anchor.size.height + gap)
    case .leading:
        return Point(x: anchor.origin.x - size.width - gap, y: centreY)
    case .trailing:
        return Point(x: anchor.origin.x + anchor.size.width + gap, y: centreY)
    }
}

/// Clamp, tolerating an inverted range: when the popup is wider than the space
/// it has, the low bound wins so it overflows off the far edge rather than the
/// near one.
private func clamp(_ value: Double, low: Double, high: Double) -> Double {
    guard high > low else { return low }
    return min(max(value, low), high)
}
