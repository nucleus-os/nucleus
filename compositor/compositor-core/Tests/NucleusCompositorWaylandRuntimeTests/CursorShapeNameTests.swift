import Testing
@testable import NucleusCompositorWaylandRuntime

// wp_cursor_shape_v1: the shape-enum → theme-name mapping that `applyCursorShape`
// realizes. Pure, so it is the one headless-testable piece of the cursor-shape path
// (the theme load + hardware-plane upload need a device).
@Suite struct CursorShapeNameTests {
    @Test func mapsTheEnumBoundaries() {
        #expect(cursorShapeName(1) == "default")
        #expect(cursorShapeName(4) == "pointer")
        #expect(cursorShapeName(9) == "text")
        #expect(cursorShapeName(17) == "grabbing")
        #expect(cursorShapeName(34) == "zoom-out")
    }

    @Test func rejectsOutOfRange() {
        // 0 and > 34 are invalid_shape (→ nil → the router posts the protocol error).
        #expect(cursorShapeName(0) == nil)
        #expect(cursorShapeName(35) == nil)
        #expect(cursorShapeName(.max) == nil)
    }

    @Test func coversEveryValidShapeWithHyphenatedNames() {
        // All 34 shapes map to a non-empty name; multi-word shapes use the CSS
        // hyphenated form the XCursor theme expects (e.g. "e-resize", not "e_resize").
        for shape in UInt32(1)...34 {
            let name = cursorShapeName(shape)
            #expect(name != nil)
            #expect(name?.contains("_") == false)
            #expect(name?.isEmpty == false)
        }
    }
}
