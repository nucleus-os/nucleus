// wp-cursor-shape-v1 on the router — named cursor shapes (a client requests a
// themed cursor instead of attaching a buffer). The manager mints a per-pointer
// device; set_shape maps the named shape to the compositor's global cursor through
// the delegate and live XCursor/renderer path. The cursor is compositor-global,
// so a device carries only the pointer authorization source.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes

/// The seam to the cursor renderer. Returns false for an unknown shape, which
/// the router turns into the protocol's invalid_shape error.
@MainActor
protocol CursorShapeDelegate: AnyObject {
    func applyCursorShape(_ shape: UInt32) -> Bool
}

@MainActor
final class CursorShapeManager {
    weak var delegate: (any CursorShapeDelegate)?

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            WpCursorShapeManagerV1Server.global(
                implementation: self,
                advertisedVersion: 1))
    }
}

extension CursorShapeManager: WpCursorShapeManagerV1Requests {
    /// Both get_pointer and get_tablet_tool_v2 mint the same device kind; the cursor
    /// is global, so the pointer/tablet arg only names which input the device tracks
    /// (unused today — the shape applies to the one global cursor).
    func getPointer(
        _ request: WaylandRequest<WpCursorShapeManagerV1Server>,
        cursor_shape_device: WlNewId<WpCursorShapeDeviceV1Server>,
        pointer: WaylandBorrowedObject<WlPointerServer>
    ) {
        let pointerOwner = pointer.owner(as: WlPointer.self)
        _ = cursor_shape_device.create { handle in
            CursorShapeDevice(
                resource: handle,
                manager: self,
                pointer: pointerOwner)
        }
    }

    func getTabletToolV2(
        _ request: WaylandRequest<WpCursorShapeManagerV1Server>,
        cursor_shape_device: WlNewId<WpCursorShapeDeviceV1Server>,
        tablet_tool: WaylandBorrowedObject<ZwpTabletToolV2Server>
    ) {
        _ = cursor_shape_device.create { handle in
            CursorShapeDevice(
                resource: handle, manager: self, pointer: nil)
        }
    }
}

/// Map a `wp_cursor_shape_v1` shape enum (1–34) to its XCursor / CSS cursor name, or
/// nil for an out-of-range value (which `set_shape` turns into the protocol's
/// `invalid_shape` error). The name feeds the theme lookup (`CursorTheme.load`), which
/// falls back to the default arrow for any name the active theme lacks — so an
/// exotic-but-valid shape still yields a cursor rather than a protocol error.
func cursorShapeName(_ shape: UInt32) -> String? {
    // Indexed by shape - 1; order matches the protocol enum exactly.
    let names = [
        "default", "context-menu", "help", "pointer", "progress", "wait", "cell",
        "crosshair", "text", "vertical-text", "alias", "copy", "move", "no-drop",
        "not-allowed", "grab", "grabbing", "e-resize", "n-resize", "ne-resize",
        "nw-resize", "s-resize", "se-resize", "sw-resize", "w-resize", "ew-resize",
        "ns-resize", "nesw-resize", "nwse-resize", "col-resize", "row-resize",
        "all-scroll", "zoom-in", "zoom-out",
    ]
    guard shape >= 1, shape <= UInt32(names.count) else { return nil }
    return names[Int(shape) - 1]
}

/// A wp_cursor_shape_device_v1: maps set_shape to the global cursor.
@MainActor
final class CursorShapeDevice {
    private let resource:
        WaylandResourceHandle<WpCursorShapeDeviceV1Server>
    private unowned let manager: CursorShapeManager
    private weak var pointer: WlPointer?
    init(
        resource: WaylandResourceHandle<WpCursorShapeDeviceV1Server>,
        manager: CursorShapeManager,
        pointer: WlPointer?
    ) {
        self.resource = resource
        self.manager = manager
        self.pointer = pointer
    }
}

extension CursorShapeDevice: WpCursorShapeDeviceV1Requests {
    func setShape(_ request: WaylandRequest<WpCursorShapeDeviceV1Server>, serial: UInt32, shape: WpCursorShapeDeviceV1Shape) {
        guard pointer?.authorizesCursor(serial: serial) == true else { return }
        let ok = manager.delegate?.applyCursorShape(shape.rawValue) ?? false
        if !ok {
            request.postError(.invalidShape, message: "unknown cursor shape")
        }
    }
}
