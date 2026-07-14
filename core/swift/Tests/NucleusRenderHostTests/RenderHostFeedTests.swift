// Converted from RenderHostFixture (Phase 10b.6b): the layers→render
// producer feed. Drives the real layers API with a RenderCommitSink
// installed and asserts the RetainedTreeStore tree + the lowered transaction the
// sink captures. Hardware-independent. One ordered @Test: the invariants share a
// Context/sink and assert a monotonic store revision, so they cannot be split
// (swift-testing runs @Test funcs in arbitrary order / in parallel).

import Testing
import NucleusTypes
@_spi(NucleusCompositor) import NucleusLayers
import NucleusRenderModel
@testable import NucleusRenderHost

@Suite struct RenderHostFeedTests {
    @Test @MainActor func acceptedSceneCommitRequestsAFrame() throws {
        var requests = 0
        SceneCommitFrameDemand.install { requests += 1 }
        defer { SceneCommitFrameDemand.clear() }
        let sink = RenderCommitSink(store: RetainedTreeStore())
        let context = try NucleusLayers.Context(id: ContextID(rawValue: 901), commitSink: sink)
        var transaction = NucleusLayers.LayerTransaction(context: context)
        let layer = transaction.createLayer()
        try transaction.insert(layer)
        try transaction.commit()
        #expect(requests == 1)
        #expect(sink.store.hasPendingDamage)
    }

    @Test @MainActor func layersToRenderFeed() throws {
        // The shell-overlay context so the .none/.default material role derives
        // .shellOverlay (matching the host's context-derived path).
        let sink = RenderCommitSink()
        let ctx = try NucleusLayers.Context(id: .shellOverlay, commitSink: sink)

        var nextIndex: UInt32 = 0
        func freshIndex() -> UInt32 { defer { nextIndex += 1 }; return nextIndex }

        // Invariant 1 + 6: a container with a non-.none backdrop material →
        // populated backdropAttachment; the store revision + present-dirty advance.
        let popover = NucleusLayers.BackdropMaterial(
            material: .popover, blendingMode: .behindWindow, state: .active,
            appearance: .dark, cornerRadius: 18, opacity: 0.9,
            tint: NucleusTypes.Color(r: 0.1, g: 0.2, b: 0.3, a: 0.8))
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            let root = t.createLayer(NucleusLayers.LayerDescriptor(
                kind: .container,
                frame: NucleusLayers.GeometryRect(x: 0, y: 0, width: 200, height: 100),
                opacity: 1, backdropMaterial: popover, backdropGroupID: 42))
            try t.insert(root, into: nil, at: freshIndex())
            try t.commit()

            #expect(sink.store.revision == 1, "first-revision")
            #expect(sink.store.presentDirty, "first-dirty")
            #expect(sink.store.hasPendingDamage, "first-damage")
            #expect(sink.store.snapshot().roots(for: NucleusRenderModel.shellOverlayContextId) == [root.id.rawValue], "first-root")

            let node = sink.store.snapshot().get(root.id.rawValue)
            #expect(node != nil, "first-node-present")
            let attachment = node?.backdropAttachment
            #expect(attachment != nil, "backdrop-attachment-present")
            #expect(attachment?.materialRole == .popover, "backdrop-role")
            #expect(attachment?.blendingMode == .behindWindow, "backdrop-blend")
            #expect(attachment?.appearance == .dark, "backdrop-appearance")
            #expect(attachment?.groupId == 42, "backdrop-group")
            if case .rrect(_, let radii)? = attachment?.shape {
                #expect(radii.0 == 18 && radii.1 == 18 && radii.2 == 18 && radii.3 == 18, "backdrop-rounded-shape")
            } else {
                #expect(Bool(false), "backdrop-rounded-shape")
            }
        }

        // Invariant 2: a created layer with .none material has nil attachment.
        var plainID: NucleusLayers.LayerID? = nil
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            let plain = t.createLayer(NucleusLayers.LayerDescriptor(
                kind: .container,
                frame: NucleusLayers.GeometryRect(x: 0, y: 0, width: 50, height: 50),
                opacity: 1, backdropMaterial: .none))
            plainID = plain.id
            try t.insert(plain, into: nil, at: freshIndex())
            try t.commit()
            #expect(sink.store.snapshot().get(plain.id.rawValue)?.backdropAttachment == nil, "none-material-nil-attachment")
            #expect(sink.store.revision == 2, "second-revision")
        }

        // Invariant 3a: default-action position+bounds → compound frame write.
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            let layer = t.createLayer(NucleusLayers.LayerDescriptor(kind: .container))
            try t.insert(layer, into: nil, at: freshIndex())
            var update = NucleusLayers.LayerPropertyUpdate(actionPolicy: .default)
            update.position = NucleusLayers.GeometryPoint(x: 10.25, y: 20.5)
            update.bounds = NucleusLayers.GeometrySize(width: 300.75, height: 120.125)
            try t.setProperties(update, for: layer)
            try t.commit()

            let pu = sink.lastLowered?.propertyUpdates.first { $0.nodeId == layer.id.rawValue }
            #expect(pu?.frame == NucleusRenderModel.Frame(left: 10.25, top: 20.5, right: 311.0, bottom: 140.625), "default-action-compound-frame")
            #expect(pu?.position == nil, "default-action-no-position")
            #expect(pu?.bounds == nil, "default-action-no-bounds")

            let node = sink.store.snapshot().get(layer.id.rawValue)
            #expect(node?.model.properties.position == NucleusRenderModel.Point2D(x: 10.25, y: 20.5), "default-action-frame-position")
            #expect(node?.model.properties.bounds == NucleusRenderModel.Bounds(w: 300.75, h: 120.125), "default-action-frame-bounds")
        }

        // Invariant 3b: no-animation policy keeps separate position + bounds.
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            let layer = t.createLayer(NucleusLayers.LayerDescriptor(kind: .container))
            try t.insert(layer, into: nil, at: freshIndex())
            var update = NucleusLayers.LayerPropertyUpdate(actionPolicy: .none)
            update.position = NucleusLayers.GeometryPoint(x: 10.25, y: 20.5)
            update.bounds = NucleusLayers.GeometrySize(width: 300.75, height: 120.125)
            try t.setProperties(update, for: layer)
            try t.commit()

            let pu = sink.lastLowered?.propertyUpdates.first { $0.nodeId == layer.id.rawValue }
            #expect(pu?.frame == nil, "no-animation-no-frame")
            #expect(pu?.position == NucleusRenderModel.Point2D(x: 10.25, y: 20.5), "no-animation-position")
            #expect(pu?.bounds == NucleusRenderModel.Bounds(w: 300.75, h: 120.125), "no-animation-bounds")
        }

        // Invariant 4: content mapping (paint / external / snapshot / zero).
        func loweredContent(_ content: NucleusLayers.LayerContent) -> NucleusRenderModel.ContentDelta? {
            do {
                var t = NucleusLayers.LayerTransaction(context: ctx)
                let layer = t.createLayer(NucleusLayers.LayerDescriptor(kind: .container))
                try t.insert(layer, into: nil, at: freshIndex())
                try t.setProperties(NucleusLayers.LayerPropertyUpdate(content: content), for: layer)
                try t.commit()
                return sink.lastLowered?.propertyUpdates.first { $0.nodeId == layer.id.rawValue }?.content
            } catch { return nil }
        }
        #expect(loweredContent(NucleusLayers.LayerContent(kind: .paint, handle: 7)) == .paint(NucleusRenderModel.PaintContentHandle(raw: 7)), "content-paint")
        #expect(loweredContent(NucleusLayers.LayerContent(kind: .external, handle: 5)) == .external(NucleusRenderModel.IOSurfaceID(raw: 5)), "content-external")
        #expect(loweredContent(NucleusLayers.LayerContent(kind: .snapshot, handle: 9)) == .snapshot(NucleusRenderModel.SnapshotHandle(raw: 9)), "content-snapshot")
        #expect(loweredContent(NucleusLayers.LayerContent(kind: .paint, handle: 0)) == ContentDelta.none, "content-zero-handle-none")

        // Invariant 5: a shadow with effective alpha <= 0 → CLEAR; otherwise SET.
        func loweredShadow(_ shadow: NucleusLayers.Shadow) -> NucleusRenderModel.ShadowDelta? {
            do {
                var t = NucleusLayers.LayerTransaction(context: ctx)
                let layer = t.createLayer(NucleusLayers.LayerDescriptor(kind: .container))
                try t.insert(layer, into: nil, at: freshIndex())
                try t.setProperties(NucleusLayers.LayerPropertyUpdate(shadow: shadow), for: layer)
                try t.commit()
                return sink.lastLowered?.propertyUpdates.first { $0.nodeId == layer.id.rawValue }?.shadow
            } catch { return nil }
        }
        #expect(loweredShadow(NucleusLayers.Shadow(opacity: 0, color: NucleusTypes.Color(r: 0, g: 0, b: 0, a: 1))) == .clear, "shadow-zero-alpha-clear")
        if case .set(let s)? = loweredShadow(NucleusLayers.Shadow(blurRadius: 4, opacity: 0.5, color: NucleusTypes.Color(r: 0, g: 0, b: 0, a: 1))) {
            #expect(s.blurRadius == 4 && s.color.a == 0.5, "shadow-set")
        } else {
            #expect(Bool(false), "shadow-set")
        }

        // Invariant 6: removal folds through; revision + present-dirty advance.
        let revBefore = sink.store.revision
        let plain = try #require(plainID)
        let plainLayer = try #require(ctx.layers[plain])
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            try t.remove(plainLayer)
            try t.commit()
            #expect(sink.store.snapshot().get(plain.rawValue) == nil, "removed-gone")
            #expect(sink.store.revision == revBefore + 1, "remove-revision-advance")
            #expect(sink.store.presentDirty, "remove-dirty")
        }
    }
}
