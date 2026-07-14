// X11 scale / DPI plumbing for Xwayland clients — the data half.
//
// Exposes the compositor's fractional scale to X11 apps via two mechanisms:
//   1. RESOURCE_MANAGER — an Xrdb-format string on the root window (Xft.dpi etc.),
//      read by Xft-based apps (xterm, GIMP, older Qt/Motif).
//   2. XSETTINGS — the binary protocol GTK3+/recent Qt read, with Xft/DPI,
//      Gdk/WindowScalingFactor, Gdk/UnscaledDPI.
//
// This file is pure data: the byte-exact XSETTINGS payload and the Xrdb string.
// The connection-bound publisher (the hidden selection window, change_property)
// lands with the XWM connection-ownership cutover. These functions are the
// parity-critical part — toolkits depend on the exact byte layout — so they port
// and get tested first.

/// The Xrdb-format RESOURCE_MANAGER string for `scale`. The subset of Xrdb syntax
/// Xft/GTK/Qt all grok.
func resourceManagerString(scale: Double) -> String {
    let dpi = Int((96.0 * scale).rounded())
    let cursor = Int((24.0 * scale).rounded())
    return "Xft.dpi:\t\(dpi)\n"
        + "Xft.antialias:\t1\n"
        + "Xft.hinting:\t1\n"
        + "Xft.hintstyle:\thintslight\n"
        + "Xft.rgba:\trgb\n"
        + "Xft.lcdfilter:\tlcddefault\n"
        + "Xcursor.size:\t\(cursor)\n"
}

/// Serialize the XSETTINGS payload for `scale` under `serial`.
/// See https://specifications.freedesktop.org/xsettings-spec/ .
///
/// Header: 1-byte byte order (LSBFirst) + 3 pad + 4-byte serial + 4-byte
/// n_settings, then each integer setting (see `appendIntSetting`). Little-endian
/// throughout.
func serializeXSettings(scale rawScale: Double, serial: UInt32) -> [UInt8] {
    let scale = rawScale <= 0 ? 1.0 : rawScale

    let xftDpi = Int32((scale * 96.0 * 1024.0).rounded())
    let gdkWindowScaling = max(1, Int32(scale.rounded()))
    let gdkUnscaledDpi = Int32(((96.0 * 1024.0) / scale).rounded())

    var buf: [UInt8] = []
    buf.append(0) // LSBFirst byte order
    buf.append(contentsOf: [0, 0, 0]) // padding
    appendLE32(&buf, serial)
    appendLE32(&buf, 3) // n_settings

    appendIntSetting(&buf, "Xft/DPI", serial: serial, value: xftDpi)
    appendIntSetting(&buf, "Gdk/WindowScalingFactor", serial: serial, value: gdkWindowScaling)
    appendIntSetting(&buf, "Gdk/UnscaledDPI", serial: serial, value: gdkUnscaledDpi)

    return buf
}

/// Append one integer setting. Layout:
///   type (1) | unused (1) | name_len (2) | name (name_len, padded to 4) |
///   last_change_serial (4) | value (4)
private func appendIntSetting(_ buf: inout [UInt8], _ name: String, serial: UInt32, value: Int32) {
    let nameBytes = Array(name.utf8)
    buf.append(0) // XSettingsTypeInteger
    buf.append(0) // unused padding
    appendLE16(&buf, UInt16(nameBytes.count))
    buf.append(contentsOf: nameBytes)

    // Pad the name to a 4-byte boundary.
    let padded = (nameBytes.count + 3) & ~3
    for _ in nameBytes.count..<padded { buf.append(0) }

    appendLE32(&buf, serial)
    appendLE32(&buf, UInt32(bitPattern: value))
}

private func appendLE16(_ buf: inout [UInt8], _ v: UInt16) {
    buf.append(UInt8(v & 0xff))
    buf.append(UInt8((v >> 8) & 0xff))
}

private func appendLE32(_ buf: inout [UInt8], _ v: UInt32) {
    buf.append(UInt8(v & 0xff))
    buf.append(UInt8((v >> 8) & 0xff))
    buf.append(UInt8((v >> 16) & 0xff))
    buf.append(UInt8((v >> 24) & 0xff))
}
