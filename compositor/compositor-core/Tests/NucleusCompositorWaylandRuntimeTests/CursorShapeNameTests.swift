import Testing
import WaylandProtocolTypes
@testable import NucleusCompositorWaylandRuntime

// wp_cursor_shape_v1: the shape-enum → theme-name mapping that `applyCursorShape`
// realizes. Pure, so it is the one headless-testable piece of the cursor-shape path
// (the theme load + hardware-plane upload need a device).
@Suite struct CursorShapeNameTests {
    @Test func mapsTheEnumBoundaries() {
        #expect(cursorShapeName(.default) == "default")
        #expect(cursorShapeName(.pointer) == "pointer")
        #expect(cursorShapeName(.text) == "text")
        #expect(cursorShapeName(.grabbing) == "grabbing")
        #expect(cursorShapeName(.zoomOut) == "zoom-out")
        #expect(cursorShapeName(.dndAsk) == "dnd-ask")
        #expect(cursorShapeName(.allResize) == "all-resize")
    }

    @Test func rejectsOutOfRange() {
        #expect(cursorShapeName(.init(rawValue: 0)) == nil)
        #expect(cursorShapeName(.init(rawValue: 37)) == nil)
        #expect(cursorShapeName(.init(rawValue: .max)) == nil)
    }

    @Test func coversEveryValidShapeWithHyphenatedNames() {
        // All protocol shapes map to a non-empty name; multi-word shapes use the CSS
        // hyphenated form the XCursor theme expects (e.g. "e-resize", not "e_resize").
        for rawValue in UInt32(1)...36 {
            let name = cursorShapeName(.init(rawValue: rawValue))
            #expect(name != nil)
            #expect(name?.contains("_") == false)
            #expect(name?.isEmpty == false)
        }
    }
}
