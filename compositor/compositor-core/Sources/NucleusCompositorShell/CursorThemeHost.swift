import NucleusCompositorServer

@MainActor public func nucleus_compositor_cursor_apply_default() {
    nucleus_compositor_cursor_apply_named(nil)
}

@MainActor public func nucleus_compositor_cursor_apply_named(_ namePtr: UnsafePointer<CChar>?) {
    let name = namePtr.map { String(cString: $0) } ?? "default"
    let resolved = name.isEmpty ? "default" : name
    // Clients re-assert the same named shape on every pointer enter; skip an unchanged
    // name to avoid a theme reload + a cursor generation bump + the forced present that
    // follows. The marker lives on the cursor model so a client `set_cursor` image (which
    // clears it) is never mistaken for the current theme cursor.
    let cursor = NucleusCompositorServer.shared.cursor
    guard resolved != cursor.themeName else { return }
    let image = CursorTheme.shared.load(name: resolved, size: 24)
    // Retain the ARGB pixels in the cursor model so the hardware cursor-plane path can
    // upload them (previously the theme pixels were loaded and discarded, leaving the
    // compositor with no visible cursor). `XCursorImage.pixels` is tightly-packed ARGB8888.
    cursor.applyTheme(
        name: resolved, pixels: [UInt8](image.pixels),
        width: image.width, height: image.height,
        hotSpotX: Int32(bitPattern: image.hotSpotX),
        hotSpotY: Int32(bitPattern: image.hotSpotY))
}
