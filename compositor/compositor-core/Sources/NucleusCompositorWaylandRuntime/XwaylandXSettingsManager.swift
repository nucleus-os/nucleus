// Connection-bound XSETTINGS / RESOURCE_MANAGER publishing. The byte-exact payloads come from
// XwaylandXSettings.swift; this owns the hidden _XSETTINGS_S0 selection window and
// the change_property calls that publish them. Lands with the XWM cutover.

import NucleusCompositorXcbC

/// Write the Xrdb-format RESOURCE_MANAGER string on the root window for `scale`.
func setResourceManager(_ conn: OpaquePointer, _ root: xcb_window_t, _ atoms: AtomTable, scale: Double) {
    let bytes = Array(resourceManagerString(scale: scale).utf8)
    bytes.withUnsafeBytes { raw in
        _ = xcb_change_property(
            conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), root,
            atoms[.RESOURCE_MANAGER], xcb_atom_t(XCB_ATOM_STRING.rawValue), 8,
            UInt32(bytes.count), raw.baseAddress)
    }
}

/// XSETTINGS manager: owns `_XSETTINGS_S0` on a hidden 1×1 window and publishes the
/// settings blob on `_XSETTINGS_SETTINGS`, bumping the serial each time so clients
/// re-read on PropertyNotify.
final class XSettingsManager {
    private let conn: OpaquePointer
    private let atoms: AtomTable
    private(set) var window: xcb_window_t
    private var serial: UInt32 = 0

    init(conn: OpaquePointer, root: xcb_window_t, rootVisual: xcb_visualid_t, atoms: AtomTable) {
        self.conn = conn
        self.atoms = atoms
        let wid = xcb_generate_id(conn)
        _ = xcb_create_window(
            conn, 0 /* XCB_COPY_FROM_PARENT depth */, wid, root,
            0, 0, 1, 1, 0,
            UInt16(XCB_WINDOW_CLASS_INPUT_OUTPUT.rawValue), rootVisual, 0, nil)
        _ = xcb_set_selection_owner(conn, wid, atoms[._XSETTINGS_S0], 0 /* XCB_CURRENT_TIME */)
        self.window = wid
    }

    func destroyWindow() {
        guard window != 0 else { return }
        _ = xcb_destroy_window(conn, window)
        window = 0
    }

    func publishScale(_ scale: Double) {
        serial &+= 1
        let payload = serializeXSettings(scale: scale, serial: serial)
        let settingsAtom = atoms[._XSETTINGS_SETTINGS]
        payload.withUnsafeBytes { raw in
            _ = xcb_change_property(
                conn, UInt8(XCB_PROP_MODE_REPLACE.rawValue), window,
                settingsAtom, settingsAtom /* type = same atom, per spec */, 8,
                UInt32(payload.count), raw.baseAddress)
        }
    }
}
