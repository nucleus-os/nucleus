import NucleusTypes
import NucleusCompositorServerTypes
import NucleusCompositorServer

private struct PopupRect: Equatable {
    var x: Int32
    var y: Int32
    var w: Int32
    var h: Int32
}

private struct ConstraintOffsets {
    var left: Int32
    var right: Int32
    var top: Int32
    var bottom: Int32

    var isUnconstrained: Bool {
        left <= 0 && right <= 0 && top <= 0 && bottom <= 0
    }
}

private struct PopupPositioner {
    var sizeW: Int32
    var sizeH: Int32
    var anchorRectX: Int32
    var anchorRectY: Int32
    var anchorRectW: Int32
    var anchorRectH: Int32
    var anchor: UInt32
    var gravity: UInt32
    var constraintAdjustment: UInt32
    var offsetX: Int32
    var offsetY: Int32

    init(wireValue c: WirePopupPositioner) {
        sizeW = c.sizeW
        sizeH = c.sizeH
        anchorRectX = c.anchorRectX
        anchorRectY = c.anchorRectY
        anchorRectW = c.anchorRectW
        anchorRectH = c.anchorRectH
        anchor = c.anchor
        gravity = c.gravity
        constraintAdjustment = c.constraintAdjustment
        offsetX = c.offsetX
        offsetY = c.offsetY
    }

    func resolve() -> PopupRect {
        var ax = anchorRectX
        var ay = anchorRectY
        switch anchor {
        case 0:
            ax += anchorRectW / 2
            ay += anchorRectH / 2
        case 1:
            ax += anchorRectW / 2
        case 2:
            ax += anchorRectW / 2
            ay += anchorRectH
        case 3:
            ay += anchorRectH / 2
        case 4:
            ax += anchorRectW
            ay += anchorRectH / 2
        case 5:
            break
        case 6:
            ay += anchorRectH
        case 7:
            ax += anchorRectW
        case 8:
            ax += anchorRectW
            ay += anchorRectH
        default:
            break
        }

        var px = ax
        var py = ay
        switch gravity {
        case 0:
            px -= sizeW / 2
            py -= sizeH / 2
        case 1:
            px -= sizeW / 2
            py -= sizeH
        case 2:
            px -= sizeW / 2
        case 3:
            px -= sizeW
            py -= sizeH / 2
        case 4:
            py -= sizeH / 2
        case 5:
            px -= sizeW
            py -= sizeH
        case 6:
            px -= sizeW
        case 7:
            py -= sizeH
        case 8:
            break
        default:
            break
        }

        return PopupRect(x: px + offsetX, y: py + offsetY, w: max(1, sizeW), h: max(1, sizeH))
    }

    var slideX: Bool { (constraintAdjustment & 1) != 0 }
    var slideY: Bool { (constraintAdjustment & 2) != 0 }
    var flipX: Bool { (constraintAdjustment & 4) != 0 }
    var flipY: Bool { (constraintAdjustment & 8) != 0 }
    var resizeX: Bool { (constraintAdjustment & 16) != 0 }
    var resizeY: Bool { (constraintAdjustment & 32) != 0 }
}

@MainActor
extension WindowManager {
    public func resolvePopup(parentID: UInt64, positioner cPositioner: WirePopupPositioner) -> WirePopupResolvedRect? {
        let positioner = PopupPositioner(wireValue: cPositioner)
        var rect = positioner.resolve()
        guard let constraint = popupConstraintRect(parentID: parentID) else {
            return rect.wireValue
        }
        var offsets = constraintOffsets(constraint: constraint, rect: rect)
        if offsets.isUnconstrained { return rect.wireValue }
        if constrainByFlip(positioner: positioner, constraint: constraint, rect: &rect, offsets: &offsets) { return rect.wireValue }
        if constrainBySlide(positioner: positioner, constraint: constraint, rect: &rect, offsets: &offsets) { return rect.wireValue }
        _ = constrainByResize(positioner: positioner, constraint: constraint, rect: &rect, offsets: &offsets)
        return rect.wireValue
    }

    private func popupConstraintRect(parentID: UInt64) -> PopupRect? {
        guard let parent = server.window(id: parentID) else { return nil }
        let outputID = parent.currentOutputID ?? server.spaces.policyOutputID(for: parent, layout: server.layout)
        guard let output = server.layout.display(id: outputID) else { return nil }
        let parentRect = parent.currentRect()
        return PopupRect(
            x: Int32((output.logicalRect.x - parentRect.x).rounded()),
            y: Int32((output.logicalRect.y - parentRect.y).rounded()),
            w: Int32(max(1, output.logicalRect.width.rounded())),
            h: Int32(max(1, output.logicalRect.height.rounded()))
        )
    }
}

private func constraintOffsets(constraint: PopupRect, rect: PopupRect) -> ConstraintOffsets {
    ConstraintOffsets(
        left: constraint.x - rect.x,
        right: rect.x + rect.w - constraint.x - constraint.w,
        top: constraint.y - rect.y,
        bottom: rect.y + rect.h - constraint.y - constraint.h
    )
}

private func anchorInvertX(_ anchor: UInt32) -> UInt32 {
    switch anchor {
    case 3: return 4
    case 4: return 3
    case 5: return 7
    case 7: return 5
    case 6: return 8
    case 8: return 6
    default: return anchor
    }
}

private func anchorInvertY(_ anchor: UInt32) -> UInt32 {
    switch anchor {
    case 1: return 2
    case 2: return 1
    case 5: return 6
    case 7: return 8
    case 6: return 5
    case 8: return 7
    default: return anchor
    }
}

private func gravityInvertX(_ gravity: UInt32) -> UInt32 { anchorInvertX(gravity) }
private func gravityInvertY(_ gravity: UInt32) -> UInt32 { anchorInvertY(gravity) }
private func gravityTowardLeft(_ gravity: UInt32) -> Bool { gravity == 3 || gravity == 5 || gravity == 6 }
private func gravityTowardTop(_ gravity: UInt32) -> Bool { gravity == 1 || gravity == 5 || gravity == 7 }

private func constrainByFlip(positioner: PopupPositioner, constraint: PopupRect, rect: inout PopupRect, offsets: inout ConstraintOffsets) -> Bool {
    let shouldFlipX = ((offsets.left > 0) != (offsets.right > 0)) && positioner.flipX
    let shouldFlipY = ((offsets.top > 0) != (offsets.bottom > 0)) && positioner.flipY
    if !shouldFlipX && !shouldFlipY { return false }

    var flipped = positioner
    if shouldFlipX {
        flipped.anchor = anchorInvertX(flipped.anchor)
        flipped.gravity = gravityInvertX(flipped.gravity)
    }
    if shouldFlipY {
        flipped.anchor = anchorInvertY(flipped.anchor)
        flipped.gravity = gravityInvertY(flipped.gravity)
    }

    let flippedRect = flipped.resolve()
    let flippedOffsets = constraintOffsets(constraint: constraint, rect: flippedRect)
    if flippedOffsets.left <= 0 && flippedOffsets.right <= 0 {
        rect.x = flippedRect.x
        offsets.left = flippedOffsets.left
        offsets.right = flippedOffsets.right
    }
    if flippedOffsets.top <= 0 && flippedOffsets.bottom <= 0 {
        rect.y = flippedRect.y
        offsets.top = flippedOffsets.top
        offsets.bottom = flippedOffsets.bottom
    }
    return offsets.isUnconstrained
}

private func constrainBySlide(positioner: PopupPositioner, constraint: PopupRect, rect: inout PopupRect, offsets: inout ConstraintOffsets) -> Bool {
    let shouldSlideX = (offsets.left > 0 || offsets.right > 0) && positioner.slideX
    let shouldSlideY = (offsets.top > 0 || offsets.bottom > 0) && positioner.slideY
    if !shouldSlideX && !shouldSlideY { return false }

    if shouldSlideX {
        if offsets.left > 0 && offsets.right > 0 {
            rect.x += gravityTowardLeft(positioner.gravity) ? -offsets.right : offsets.left
        } else {
            rect.x += abs(offsets.left) < abs(offsets.right) ? offsets.left : -offsets.right
        }
    }
    if shouldSlideY {
        if offsets.top > 0 && offsets.bottom > 0 {
            rect.y += gravityTowardTop(positioner.gravity) ? -offsets.bottom : offsets.top
        } else {
            rect.y += abs(offsets.top) < abs(offsets.bottom) ? offsets.top : -offsets.bottom
        }
    }

    offsets = constraintOffsets(constraint: constraint, rect: rect)
    return offsets.isUnconstrained
}

private func constrainByResize(positioner: PopupPositioner, constraint: PopupRect, rect: inout PopupRect, offsets: inout ConstraintOffsets) -> Bool {
    let shouldResizeX = (offsets.left > 0 || offsets.right > 0) && positioner.resizeX
    let shouldResizeY = (offsets.top > 0 || offsets.bottom > 0) && positioner.resizeY
    if !shouldResizeX && !shouldResizeY { return false }

    let left = max(0, offsets.left)
    let right = max(0, offsets.right)
    let top = max(0, offsets.top)
    let bottom = max(0, offsets.bottom)
    var resized = rect
    if shouldResizeX {
        resized.x += left
        resized.w -= left + right
    }
    if shouldResizeY {
        resized.y += top
        resized.h -= top + bottom
    }
    if resized.w <= 0 || resized.h <= 0 { return false }
    rect = resized
    offsets = constraintOffsets(constraint: constraint, rect: rect)
    return offsets.isUnconstrained
}

private extension PopupRect {
    var wireValue: WirePopupResolvedRect {
        var c = WirePopupResolvedRect()
        c.x = x
        c.y = y
        c.w = w
        c.h = h
        return c
    }
}
