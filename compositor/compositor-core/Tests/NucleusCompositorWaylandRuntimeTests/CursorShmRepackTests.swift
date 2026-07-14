import Testing
@testable import NucleusCompositorWaylandRuntime

// wl_pointer.set_cursor SHM path — the format gate + stride repack that turn a client
// cursor surface's SHM buffer into tight ARGB8888 for the cursor plane. Pure (the
// libwayland buffer access is separated out in cursorImageFromShm), so headlessly
// testable. The failure mode these guard against is an over-read of a padded/short
// client buffer.
@Suite struct CursorShmRepackTests {
    @Test func acceptsArgbAndXrgbFormatsOnly() {
        #expect(PointerCursorSurface.isReadableCursorShmFormat(0))   // WL_SHM_FORMAT_ARGB8888
        #expect(PointerCursorSurface.isReadableCursorShmFormat(1))   // WL_SHM_FORMAT_XRGB8888
        #expect(!PointerCursorSurface.isReadableCursorShmFormat(2))
        #expect(!PointerCursorSurface.isReadableCursorShmFormat(0x3432_5258))  // 'XR24' fourcc
        #expect(!PointerCursorSurface.isReadableCursorShmFormat(.max))
    }

    @Test func stripsStridePadding() {
        // 2×2, stride 12 (8 bytes of pixels + 4 bytes padding per row).
        let w = 2, h = 2, stride = 12
        var src = [UInt8](repeating: 0, count: stride * h)
        for i in 0..<8 { src[i] = UInt8(i + 1) }               // row 0 pixels
        for i in 0..<8 { src[stride + i] = UInt8(i + 100) }    // row 1 pixels (after padding)
        let out = src.withUnsafeBytes {
            PointerCursorSurface.repackTightARGB(source: $0, width: w, height: h, sourceStride: stride)
        }
        #expect(out.count == w * h * 4)  // 16 — tight, no padding
        #expect(Array(out[0..<8]) == (1...8).map { UInt8($0) })
        #expect(Array(out[8..<16]) == (100..<108).map { UInt8($0) })
    }

    @Test func tightSourceIsCopiedVerbatim() {
        let w = 3, h = 1, stride = 12  // 3*4 == 12, already tight
        let src = (0..<12).map { UInt8($0) }
        let out = src.withUnsafeBytes {
            PointerCursorSurface.repackTightARGB(source: $0, width: w, height: h, sourceStride: stride)
        }
        #expect(out == src)
    }

    @Test func rejectsUndersizedStrideWithoutOverread() {
        // stride < width*4 is invalid; return a zero-filled tight buffer, never over-read.
        let src = [UInt8](repeating: 9, count: 4)
        let out = src.withUnsafeBytes {
            PointerCursorSurface.repackTightARGB(source: $0, width: 4, height: 1, sourceStride: 4)  // needs 16 > 4
        }
        #expect(out.count == 16)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func shortSourceStopsPerRowWithoutOverread() {
        // 2 rows requested, source holds only 1.5 rows: row 0 copied, row 1 left zero.
        let w = 2, h = 2, stride = 8  // tight
        let src = [UInt8](repeating: 7, count: 8 + 4)  // one full row + a partial second
        let out = src.withUnsafeBytes {
            PointerCursorSurface.repackTightARGB(source: $0, width: w, height: h, sourceStride: stride)
        }
        #expect(out.count == 16)
        #expect(Array(out[0..<8]).allSatisfy { $0 == 7 })   // row 0 copied
        #expect(Array(out[8..<16]).allSatisfy { $0 == 0 })  // row 1 source absent → zero
    }

    @Test func zeroDimensionsYieldEmptyNoCrash() {
        let empty = [UInt8]()
        let out = empty.withUnsafeBytes {
            PointerCursorSurface.repackTightARGB(source: $0, width: 0, height: 0, sourceStride: 0)
        }
        #expect(out.isEmpty)
    }
}
