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
            [PaintDrawCommand(kind: .path, x: 0, y: 0, w: 10, h: 0, strokeWidth: 2, stroke: true)],
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

    }

    /// `==` is the re-registration gate: `publishPaint` diffs command arrays and
    /// skips re-registering when they compare equal. A stored property missing
    /// from the hand-written `==` makes two visually different commands compare
    /// equal, and the repaint is silently dropped. Vary each field in turn.
    @Test func everyPaintDrawCommandFieldParticipatesInEquality() {
        let base = PaintDrawCommand(kind: .rect, x: 1, y: 2, w: 3, h: 4)

        var mutations: [(String, PaintDrawCommand)] = []
        func vary(_ name: String, _ mutate: (inout PaintDrawCommand) -> Void) {
            var copy = base
            mutate(&copy)
            mutations.append((name, copy))
        }

        vary("kind") { $0.kind = .roundedRect }
        vary("x") { $0.x = 99 }
        vary("y") { $0.y = 99 }
        vary("w") { $0.w = 99 }
        vary("h") { $0.h = 99 }
        vary("radius") { $0.radius = 99 }
        vary("strokeWidth") { $0.strokeWidth = 99 }
        vary("fontSize") { $0.fontSize = 99 }
        vary("color") { $0.color = (0, 0, 0, 1) }
        vary("imageHandle") { $0.imageHandle = 99 }
        vary("textLayoutHandle") { $0.textLayoutHandle = 99 }
        vary("effectHandle") { $0.effectHandle = 99 }
        vary("payloadOffset") { $0.payloadOffset = 99 }
        vary("payloadLength") { $0.payloadLength = 99 }
        vary("stroke") { $0.stroke = true }
        vary("antialias") { $0.antialias = false }
        vary("evenOddFill") { $0.evenOddFill = true }
        vary("shading") { $0.shading = .linearGradient }
        vary("blend") { $0.blend = .multiply }
        vary("alpha") { $0.alpha = 0.5 }
        vary("blurSigma") { $0.blurSigma = 99 }
        vary("saturation") { $0.saturation = 99 }

        for (name, mutated) in mutations {
            #expect(mutated != base, "\(name) must participate in equality")
        }
    }

    /// Two commands differing only in which slice of the payload blob they
    /// reference must not compare equal — the case that would otherwise drop a
    /// repaint when a view redraws a different path at the same size.
    @Test func distinctPayloadSlicesAreNotEqual() {
        let a = PaintDrawCommand(
            kind: .rect, x: 0, y: 0, w: 10, h: 10, payloadOffset: 0, payloadLength: 16)
        let b = PaintDrawCommand(
            kind: .rect, x: 0, y: 0, w: 10, h: 10, payloadOffset: 16, payloadLength: 16)
        #expect(a != b, "distinct payload slices")
    }
}
