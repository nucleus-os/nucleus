// Pure retained-layer rect algebra and extent-clip helpers.

// MARK: - Extent clip

/// Accumulated clip state during the extent walk. Mirrors `ExtentClip`.
public enum ExtentClip: Equatable, Sendable {
    case none
    case rect(Rect)
    case empty
}

// MARK: - Layer-id list

/// Append `layerId` to `list` only if not already present. Mirrors
/// `appendUniqueLayerID`.
public func appendUniqueLayerID(_ list: inout [UInt64], _ layerId: UInt64) {
    if list.contains(layerId) { return }
    list.append(layerId)
}

// MARK: - Rect algebra

/// Translate a rect by an offset (size unchanged). Mirrors `offsetRect`.
public func offsetRect(_ rect: Rect, _ offset: Point2D) -> Rect {
    Rect(x: rect.x + offset.x, y: rect.y + offset.y, w: rect.w, h: rect.h)
}

/// Bounding union of two rects. Mirrors `unionRect`.
public func unionRect(_ a: Rect, _ b: Rect) -> Rect {
    let left = min(a.x, b.x)
    let top = min(a.y, b.y)
    let right = max(a.x + a.w, b.x + b.w)
    let bottom = max(a.y + a.h, b.y + b.h)
    return Rect(x: left, y: top, w: right - left, h: bottom - top)
}

/// True when the rect has strictly positive area. Mirrors `rectHasArea`.
public func rectHasArea(_ rect: Rect) -> Bool {
    rect.w > 0 && rect.h > 0
}

/// Intersection of two rects, or `nil` if they don't overlap. Mirrors
/// `intersectRect`.
public func intersectRect(_ a: Rect, _ b: Rect) -> Rect? {
    let left = max(a.x, b.x)
    let top = max(a.y, b.y)
    let right = min(a.x + a.w, b.x + b.w)
    let bottom = min(a.y + a.h, b.y + b.h)
    if right <= left || bottom <= top { return nil }
    return Rect(x: left, y: top, w: right - left, h: bottom - top)
}

/// Fold a rect into an optional accumulator, ignoring empty rects. Mirrors
/// `unionMaybeRect`.
public func unionMaybeRect(_ result: inout Rect?, _ rect: Rect) {
    if !rectHasArea(rect) { return }
    result = result.map { unionRect($0, rect) } ?? rect
}

/// Clip a rect against an `ExtentClip`: `none` passes through, `empty` rejects,
/// `rect` intersects. Empty-area input yields `nil`. Mirrors `clipExtentRect`.
public func clipExtentRect(_ clip: ExtentClip, _ rect: Rect) -> Rect? {
    if !rectHasArea(rect) { return nil }
    switch clip {
    case .none: return rect
    case .empty: return nil
    case .rect(let clipRect): return intersectRect(rect, clipRect)
    }
}

/// Linear interpolate between two rects, progress clamped to [0, 1]. Mirrors
/// `lerpRect`.
public func lerpRect(_ from: Rect, _ to: Rect, _ progress: Float) -> Rect {
    let t = min(max(progress, 0), 1)
    return Rect(
        x: from.x + (to.x - from.x) * t,
        y: from.y + (to.y - from.y) * t,
        w: from.w + (to.w - from.w) * t,
        h: from.h + (to.h - from.h) * t)
}

/// Combine a parent extent clip with this node's already-resolved local clip
/// rect (the matrix-mapped clip the caller computes once the node + matrix
/// paths exist). Mirrors the clip-propagation core of `accumulateExtentClip`:
/// `empty` is absorbing; `none` adopts the local clip; `rect` intersects with
/// the local clip and collapses to `empty` on no overlap.
public func accumulateExtentClip(_ parentClip: ExtentClip, localClip: Rect?) -> ExtentClip {
    switch parentClip {
    case .empty:
        return .empty
    case .none:
        if let clip = localClip { return .rect(clip) }
        return .none
    case .rect(let parentRect):
        guard let clip = localClip else { return .rect(parentRect) }
        if let merged = intersectRect(parentRect, clip) { return .rect(merged) }
        return .empty
    }
}
