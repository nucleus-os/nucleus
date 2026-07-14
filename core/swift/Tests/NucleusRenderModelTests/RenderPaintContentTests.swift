@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderPaintContentTests {
    @Test func renderPaintContent() {
        let store = PaintContentStore()
        #expect(store.count == 0, "initial-empty")

        // --- register a command list: fresh non-zero handle, refcount 1 ---
        let cmds: [PaintDrawCommand] = [
            PaintDrawCommand(kind: .rect, x: 0, y: 0, w: 100, h: 100, color: (0, 0, 0, 0.08)),
            PaintDrawCommand(kind: .roundedRect, x: 8, y: 8, w: 40, h: 16, radius: 4, color: (1, 1, 1, 1)),
            PaintDrawCommand(kind: .image, x: 0, y: 0, w: 100, h: 100, imageHandle: 7),
        ]
        let h = store.register(cmds, width: 120, height: 80)
        #expect(h.raw != 0, "register-nonzero")
        #expect(store.count == 1, "register-count")
        #expect(store.commands(h) == cmds, "register-roundtrip")
        #expect(store.content(h)?.width == 120, "authored-width-roundtrip")
        #expect(store.content(h)?.height == 80, "authored-height-roundtrip")

        // --- a second registration gets a distinct handle ---
        let h2 = store.register(
            [PaintDrawCommand(kind: .line, x: 0, y: 0, w: 10, h: 0, strokeWidth: 2)],
            width: 10, height: 10)
        #expect(h2.raw != h.raw, "distinct-handle")
        #expect(store.count == 2, "second-count")

        // --- retain then release keeps the entry until the last ref drops ---
        store.retain(h)            // refs: 2
        store.release(h)           // refs: 1
        #expect(store.commands(h) != nil, "retain-keeps")
        store.release(h)           // refs: 0 -> evict
        #expect(store.commands(h) == nil, "release-evicts")
        #expect(store.count == 1, "evict-count")

        // --- release of an unknown handle is a no-op ---
        store.release(PaintContentHandle(raw: 9999))
        #expect(store.count == 1, "unknown-release-noop")

        // --- wire discriminant mapping (reserved 0/3 drop) ---
        #expect(paintDrawCommandKind(1) == .rect, "wire-rect")
        #expect(paintDrawCommandKind(2) == .roundedRect, "wire-rounded")
        #expect(paintDrawCommandKind(4) == .image, "wire-image")
        #expect(paintDrawCommandKind(5) == .line, "wire-line")
        #expect(paintDrawCommandKind(6) == .textLayout, "wire-text")
        #expect(paintDrawCommandKind(0) == nil && paintDrawCommandKind(3) == nil, "wire-reserved-drop")
    }
}
