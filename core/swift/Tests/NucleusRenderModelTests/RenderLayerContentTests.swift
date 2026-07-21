@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderLayerContentTests {
    @Test func renderLayerContent() {
        // Handle sentinels: raw 0 is `none`, non-zero is not.
        #expect(SnapshotHandle.none.isNone && !SnapshotHandle(raw: 7).isNone, "snapshot-none")
        #expect(PaintContentHandle.none.isNone && !PaintContentHandle(raw: 1).isNone, "paint-none")
        #expect(IOSurfaceID.none.isNone && !IOSurfaceID(raw: 3).isNone, "iosurface-none")

        // Content union equality is by case + payload.
        #expect(LayerContent.paint(PaintContentHandle(raw: 5)) == .paint(PaintContentHandle(raw: 5)),
              "content-paint-equal")
        #expect(LayerContent.paint(PaintContentHandle(raw: 5)) != .paint(PaintContentHandle(raw: 6)),
              "content-paint-differs")
        #expect(LayerContent.external(IOSurfaceID(raw: 1)) != .snapshot(SnapshotHandle(raw: 1)),
              "content-case-differs")

        // InitialContent lowers to the matching LayerContent.
        #expect(InitialContent.snapshot(SnapshotHandle(raw: 9)).resolved() == .snapshot(SnapshotHandle(raw: 9)),
              "initial-resolves")
        #expect(InitialContent.none.resolved() == .none, "initial-none-resolves")

        // ContentDelta.apply: unchanged is identity; every other case overwrites.
        let base = LayerContent.paint(PaintContentHandle(raw: 2))
        #expect(ContentDelta.unchanged.apply(to: base) == base, "delta-unchanged-identity")
        #expect(ContentDelta.none.apply(to: base) == .none, "delta-none-clears")
        #expect(ContentDelta.external(IOSurfaceID(raw: 4)).apply(to: base) == .external(IOSurfaceID(raw: 4)),
              "delta-external-overwrites")

        // EffectShape equality across cases and payloads.
        #expect(EffectShape.rect((0, 0, 10, 20)) == .rect((0, 0, 10, 20)), "shape-rect-equal")
        #expect(EffectShape.rect((0, 0, 10, 20)) != .rect((0, 0, 10, 21)), "shape-rect-differs")
        #expect(EffectShape.rrect(rect: (0, 0, 4, 4), radii: (1, 1, 1, 1)) ==
              .rrect(rect: (0, 0, 4, 4), radii: (1, 1, 1, 1)), "shape-rrect-equal")
        #expect(EffectShape.rect((0, 0, 4, 4)) != .rrect(rect: (0, 0, 4, 4), radii: (0, 0, 0, 0)),
              "shape-case-differs")

        // BackdropMask equality.
        #expect(BackdropMask.roundedRect(8) == .roundedRect(8), "mask-rrect-equal")
        #expect(BackdropMask.image(SnapshotHandle(raw: 1)) != .none, "mask-image-not-none")

        // BackdropAttachment structural equality + default tail fields.
        var attach = BackdropAttachment(
            materialRole: .sidebar, blendingMode: .behindWindow, state: .active,
            appearance: .dark, emphasized: true, mask: .roundedRect(6),
            shape: .rect((0, 0, 100, 40)))
        #expect(attach.tint == (0, 0, 0, 0) && attach.opacity == 1 && attach.groupId == 0,
              "attach-defaults")
        var attach2 = attach
        #expect(attach == attach2, "attach-equal")
        attach2.emphasized = false
        #expect(attach != attach2, "attach-emphasized-differs")
        attach2 = attach
        attach2.opacity = 0.5
        #expect(attach != attach2, "attach-opacity-differs")

        // LayerKind cases.
        #expect(LayerKind.container == .container, "kind-container-equal")
        #expect(LayerKind.remoteHost(ContextID(raw: 7)) == .remoteHost(ContextID(raw: 7)),
              "kind-remote-equal")
        #expect(LayerKind.remoteHost(ContextID(raw: 7)) != .remoteHost(ContextID(raw: 8)),
              "kind-remote-differs")
        let bk = BackdropKindParams(shape: .rect((0, 0, 1, 1)))
        #expect(bk.materialRole == .default && bk.appearance == .auto && bk.state == .active &&
              !bk.emphasized, "kind-backdrop-defaults")
        #expect(LayerKind.backdrop(bk) != .container, "kind-backdrop-not-container")

        // Mutating attach silences the unused-var warning and exercises the var.
        attach.groupId = 1
        #expect(attach.groupId == 1, "attach-mutable")
    }
}
