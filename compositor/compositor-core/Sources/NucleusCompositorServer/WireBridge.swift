import NucleusTypes
package import NucleusCompositorServerTypes

private func has(_ mask: UInt64, _ bit: UInt64) -> Bool {
    (mask & bit) != 0
}

// `LogicalRect`/`RenderRect`/`PixelSize`/`UsableArea`/`DisplayMode` (Display.swift),
// `WindowEdgeInsets` (WindowChrome.swift), and `RequestedSpecialMode` (Spaces.swift)
// are the generated wire types themselves — `.wireValue`/`init(wireValue:)` are
// identity and the callers use the value directly. The converters below cover the
// domain types that are not identical to their wire form.

extension DisplayConfiguration {
    init(wireValue c: WireDisplayConfiguration) {
        self.init(
            enabled: c.enabled,
            primary: c.primary,
            logicalX: c.logicalX,
            logicalY: c.logicalY,
            logicalWidth: c.logicalWidth > 0 ? c.logicalWidth : nil,
            logicalHeight: c.logicalHeight > 0 ? c.logicalHeight : nil,
            scale: c.scale,
            fractionalScale: c.fractionalScale,
            mode: c.mode
        )
    }
}

extension DisplayConfigurationChanges {
    init(wireValue c: WireDisplayConfigurationChanges) {
        self.init()
        let mask = c.mask
        if has(mask, UInt64(displayChangeEnabled)) { enabled = c.enabled }
        if has(mask, UInt64(displayChangePrimary)) { primary = c.primary }
        if has(mask, UInt64(displayChangeLogicalX)) { logicalX = c.logicalX }
        if has(mask, UInt64(displayChangeLogicalY)) { logicalY = c.logicalY }
        if has(mask, UInt64(displayChangeLogicalWidth)) { logicalWidth = c.logicalWidth }
        if has(mask, UInt64(displayChangeLogicalHeight)) { logicalHeight = c.logicalHeight }
        if has(mask, UInt64(displayChangeScale)) { scale = c.scale }
        if has(mask, UInt64(displayChangeFractionalScale)) { fractionalScale = c.fractionalScale }
        if has(mask, UInt64(displayChangeMode)) { mode = c.mode }
    }
}

extension WindowRect {
    package init(wireValue c: WireWindowRect) {
        self.init(x: c.x, y: c.y, width: c.width, height: c.height)
    }

    package var wireValue: WireWindowRect {
        var c = WireWindowRect()
        c.x = x
        c.y = y
        c.width = width
        c.height = height
        return c
    }
}
