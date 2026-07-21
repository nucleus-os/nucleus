import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// Protocol state for one xdg_positioner. Request validation is performed at
/// this resource boundary; policy receives only a complete immutable snapshot.
final class XdgPositioner {
    var sizeW: Int32 = 0
    var sizeH: Int32 = 0
    var anchorRect = WlRect(x: 0, y: 0, width: 0, height: 0)
    var anchor: UInt32 = 0
    var gravity: UInt32 = 0
    var constraintAdjustment: UInt32 = 0
    var offsetX: Int32 = 0
    var offsetY: Int32 = 0
    var reactive = false
    var parentWidth: Int32 = 0
    var parentHeight: Int32 = 0
    var parentConfigureSerial: UInt32?

    var isComplete: Bool {
        sizeW > 0 && sizeH > 0
            && anchorRect.width > 0 && anchorRect.height > 0
    }

    func snapshot() -> XdgPositionerSnapshot? {
        guard isComplete else { return nil }
        return XdgPositionerSnapshot(
            sizeW: sizeW,
            sizeH: sizeH,
            anchorRect: anchorRect,
            anchor: anchor,
            gravity: gravity,
            constraintAdjustment: constraintAdjustment,
            offsetX: offsetX,
            offsetY: offsetY,
            reactive: reactive,
            parentWidth: parentWidth,
            parentHeight: parentHeight,
            parentConfigureSerial: parentConfigureSerial)
    }

    func resolve() -> WlRect {
        let width = max(1, sizeW)
        let height = max(1, sizeH)
        let isLeft: (UInt32) -> Bool = { $0 == 3 || $0 == 5 || $0 == 6 }
        let isRight: (UInt32) -> Bool = { $0 == 4 || $0 == 7 || $0 == 8 }
        let isTop: (UInt32) -> Bool = { $0 == 1 || $0 == 5 || $0 == 7 }
        let isBottom: (UInt32) -> Bool = { $0 == 2 || $0 == 6 || $0 == 8 }

        var anchorX = anchorRect.x + anchorRect.width / 2
        if isLeft(anchor) {
            anchorX = anchorRect.x
        } else if isRight(anchor) {
            anchorX = anchorRect.x + anchorRect.width
        }
        var anchorY = anchorRect.y + anchorRect.height / 2
        if isTop(anchor) {
            anchorY = anchorRect.y
        } else if isBottom(anchor) {
            anchorY = anchorRect.y + anchorRect.height
        }

        var x = anchorX - width / 2
        if isLeft(gravity) {
            x = anchorX - width
        } else if isRight(gravity) {
            x = anchorX
        }
        var y = anchorY - height / 2
        if isTop(gravity) {
            y = anchorY - height
        } else if isBottom(gravity) {
            y = anchorY
        }
        return WlRect(
            x: x + offsetX,
            y: y + offsetY,
            width: width,
            height: height)
    }
}

struct XdgPositionerSnapshot: Equatable {
    let sizeW: Int32
    let sizeH: Int32
    let anchorRect: WlRect
    let anchor: UInt32
    let gravity: UInt32
    let constraintAdjustment: UInt32
    let offsetX: Int32
    let offsetY: Int32
    let reactive: Bool
    let parentWidth: Int32
    let parentHeight: Int32
    let parentConfigureSerial: UInt32?

    func resolve() -> WlRect {
        let positioner = XdgPositioner()
        positioner.sizeW = sizeW
        positioner.sizeH = sizeH
        positioner.anchorRect = anchorRect
        positioner.anchor = anchor
        positioner.gravity = gravity
        positioner.constraintAdjustment = constraintAdjustment
        positioner.offsetX = offsetX
        positioner.offsetY = offsetY
        return positioner.resolve()
    }

    func isValid(parentWidth: Int32, parentHeight: Int32) -> Bool {
        guard parentWidth > 0, parentHeight > 0,
              anchorRect.x >= 0, anchorRect.y >= 0
        else { return false }
        let anchorMaxX = Int64(anchorRect.x) + Int64(anchorRect.width)
        let anchorMaxY = Int64(anchorRect.y) + Int64(anchorRect.height)
        guard anchorMaxX <= Int64(parentWidth),
              anchorMaxY <= Int64(parentHeight)
        else { return false }

        let child = resolve()
        let childMaxX = Int64(child.x) + Int64(child.width)
        let childMaxY = Int64(child.y) + Int64(child.height)
        return Int64(child.x) <= Int64(parentWidth)
            && childMaxX >= 0
            && Int64(child.y) <= Int64(parentHeight)
            && childMaxY >= 0
    }
}

extension XdgPositioner: XdgPositionerRequests {
    func setSize(
        _ resource: UnsafeMutablePointer<wl_resource>,
        width: Int32,
        height: Int32
    ) {
        guard width > 0, height > 0 else {
            swift_wayland_resource_post_error(
                resource, 0, "positioner size must be positive")
            return
        }
        sizeW = width
        sizeH = height
    }

    func setAnchorRect(
        _ resource: UnsafeMutablePointer<wl_resource>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {
        guard width >= 0, height >= 0 else {
            swift_wayland_resource_post_error(
                resource,
                0,
                "anchor rectangle dimensions must not be negative")
            return
        }
        anchorRect = WlRect(x: x, y: y, width: width, height: height)
    }

    func setAnchor(
        _ resource: UnsafeMutablePointer<wl_resource>,
        anchor: UInt32
    ) {
        guard anchor <= 8 else {
            swift_wayland_resource_post_error(
                resource, 0, "invalid positioner anchor")
            return
        }
        self.anchor = anchor
    }

    func setGravity(
        _ resource: UnsafeMutablePointer<wl_resource>,
        gravity: UInt32
    ) {
        guard gravity <= 8 else {
            swift_wayland_resource_post_error(
                resource, 0, "invalid positioner gravity")
            return
        }
        self.gravity = gravity
    }

    func setConstraintAdjustment(
        _ resource: UnsafeMutablePointer<wl_resource>,
        constraint_adjustment: UInt32
    ) {
        guard constraint_adjustment & ~UInt32(0x3f) == 0 else {
            swift_wayland_resource_post_error(
                resource, 0, "invalid constraint-adjustment mask")
            return
        }
        constraintAdjustment = constraint_adjustment
    }

    func setOffset(
        _ resource: UnsafeMutablePointer<wl_resource>,
        x: Int32,
        y: Int32
    ) {
        offsetX = x
        offsetY = y
    }

    func setReactive(_ resource: UnsafeMutablePointer<wl_resource>) {
        reactive = true
    }

    func setParentSize(
        _ resource: UnsafeMutablePointer<wl_resource>,
        parent_width: Int32,
        parent_height: Int32
    ) {
        guard parent_width > 0, parent_height > 0 else {
            swift_wayland_resource_post_error(
                resource, 0, "parent size must be positive")
            return
        }
        parentWidth = parent_width
        parentHeight = parent_height
    }

    func setParentConfigure(
        _ resource: UnsafeMutablePointer<wl_resource>,
        serial: UInt32
    ) {
        parentConfigureSerial = serial
    }
}
