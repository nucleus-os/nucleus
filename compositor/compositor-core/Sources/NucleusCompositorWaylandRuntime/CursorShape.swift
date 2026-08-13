// wp-cursor-shape-v1 on the router — named cursor shapes (a client requests a
// themed cursor instead of attaching a buffer). The manager mints a per-pointer
// device; set_shape maps the named shape to the compositor's global cursor through
// the delegate and live XCursor/renderer path. The cursor is compositor-global,
// so a device carries only the pointer authorization source.

import WaylandProtocolTypes
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

/// The seam to the cursor renderer. Returns false for an unknown shape, which
/// the router turns into the protocol's invalid_shape error.
@MainActor
protocol CursorShapeDelegate: AnyObject {
    func applyCursorShape(_ shape: WpCursorShapeDeviceV1Shape) -> Bool
}

@MainActor
protocol CursorShapeAuthorizationSource: AnyObject {
    func authorizesCursor(serial: UInt32) -> Bool
}

@MainActor
final class CursorShapeManager {
    weak var delegate: (any CursorShapeDelegate)?

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
        guard pointer.clientID == cursor_shape_device.clientID,
            let pointerOwner = pointer.owner(as: WlPointer.self)
        else { return }
        _ = cursor_shape_device.create { handle in
            CursorShapeDevice(
                resource: handle,
                manager: self,
                authorizationSource: pointerOwner)
        }
    }

    func getTabletToolV2(
        _ request: WaylandRequest<WpCursorShapeManagerV1Server>,
        cursor_shape_device: WlNewId<WpCursorShapeDeviceV1Server>,
        tablet_tool: WaylandBorrowedObject<ZwpTabletToolV2Server>
    ) {
        guard tablet_tool.clientID == cursor_shape_device.clientID,
            let tool = tablet_tool.owner(as: TabletToolResource.self)
        else { return }
        _ = cursor_shape_device.create { handle in
            CursorShapeDevice(
                resource: handle, manager: self, authorizationSource: tool)
        }
    }
}

/// Map a `wp_cursor_shape_v1` shape enum to its XCursor / CSS cursor name, or
/// nil for an out-of-range value (which `set_shape` turns into the protocol's
/// `invalid_shape` error). The name feeds the theme lookup (`CursorTheme.load`), which
/// falls back to the default arrow for any name the active theme lacks — so an
/// exotic-but-valid shape still yields a cursor rather than a protocol error.
func cursorShapeName(_ shape: WpCursorShapeDeviceV1Shape) -> String? {
    shape.knownName?
        .split(separator: "_", omittingEmptySubsequences: false)
        .joined(separator: "-")
}

/// A wp_cursor_shape_device_v1: maps set_shape to the global cursor.
@MainActor
final class CursorShapeDevice {
    private let resource: WaylandResourceHandle<WpCursorShapeDeviceV1Server>
    private unowned let manager: CursorShapeManager
    private weak var authorizationSource: (any CursorShapeAuthorizationSource)?
    init(
        resource: WaylandResourceHandle<WpCursorShapeDeviceV1Server>,
        manager: CursorShapeManager,
        authorizationSource: any CursorShapeAuthorizationSource
    ) {
        self.resource = resource
        self.manager = manager
        self.authorizationSource = authorizationSource
    }
}

extension CursorShapeDevice: WpCursorShapeDeviceV1Requests {
    func setShape(
        _ request: WaylandRequest<WpCursorShapeDeviceV1Server>, serial: UInt32,
        shape: WpCursorShapeDeviceV1Shape
    ) {
        guard authorizationSource?.authorizesCursor(serial: serial) == true else { return }
        let ok = manager.delegate?.applyCursorShape(shape) ?? false
        if !ok {
            request.postError(.invalidShape, message: "unknown cursor shape")
        }
    }
}
