// wp-cursor-shape-v1 on the router — named cursor shapes (a client requests a
// themed cursor instead of attaching a buffer). The manager mints a per-pointer
// device; set_shape maps the named shape to the compositor's global cursor through
// the delegate (the xcursor theme + renderer are #12). The cursor is compositor-
// global, so a device carries no per-pointer state — get_pointer only mints it.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// The seam to the cursor renderer (#12). Returns false for an unknown shape, which
/// the router turns into the protocol's invalid_shape error.
protocol CursorShapeDelegate: AnyObject {
    func applyCursorShape(_ shape: UInt32) -> Bool
}

final class CursorShapeManagerBinding {
    unowned let manager: CursorShapeManager
    init(_ manager: CursorShapeManager) { self.manager = manager }
}

final class CursorShapeManager {
    weak var delegate: CursorShapeDelegate?

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_wp_cursor_shape_manager_v1(), version: 2, impl: self, bind: Self.bind)
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: CursorShapeManager.self) else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wp_cursor_shape_manager_v1(), version: Int32(version),
            id: id, vtable: WpCursorShapeManagerV1Server.vtable, owner: CursorShapeManagerBinding(me))
    }
}

extension CursorShapeManagerBinding: WpCursorShapeManagerV1Requests {
    /// Both get_pointer and get_tablet_tool_v2 mint the same device kind; the cursor
    /// is global, so the pointer/tablet arg only names which input the device tracks
    /// (unused today — the shape applies to the one global cursor).
    func getPointer(
        _ resource: UnsafeMutablePointer<wl_resource>, cursor_shape_device: WlNewId,
        pointer: UnsafeMutablePointer<wl_resource>?
    ) {
        _ = cursor_shape_device.create(
            vtable: WpCursorShapeDeviceV1Server.vtable, owner: CursorShapeDevice(manager: manager))
    }

    func getTabletToolV2(
        _ resource: UnsafeMutablePointer<wl_resource>, cursor_shape_device: WlNewId,
        tablet_tool: UnsafeMutablePointer<wl_resource>?
    ) {
        _ = cursor_shape_device.create(
            vtable: WpCursorShapeDeviceV1Server.vtable, owner: CursorShapeDevice(manager: manager))
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
final class CursorShapeDevice {
    private unowned let manager: CursorShapeManager
    init(manager: CursorShapeManager) { self.manager = manager }
}

extension CursorShapeDevice: WpCursorShapeDeviceV1Requests {
    func setShape(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32, shape: UInt32) {
        // The serial (a per-enter latch) is unused — the cursor is compositor-global.
        let ok = manager.delegate?.applyCursorShape(shape) ?? true
        if !ok {
            swift_wayland_resource_post_error(resource, 1 /* invalid_shape */, "unknown cursor shape")
        }
    }
}
