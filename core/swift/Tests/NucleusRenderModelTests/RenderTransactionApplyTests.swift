@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderTransactionApplyTests {
    @Test func renderTransactionApply() {
        let ctx = ContextID(raw: 1)

        // --- created: new node carries initial state + damage ---
        var tree = LayerTree()
        var t = Transaction(contextId: ctx)
        var c = LayerCreated(nodeId: 1, kind: .container)
        c.position = Point2D(x: 5, y: 6)
        c.bounds = Bounds(w: 100, h: 50)
        c.opacity = 0.8
        c.initialContent = .paint(PaintContentHandle(raw: 7))
        t.created.append(c)
        TransactionApplier.apply(t, to: &tree)
        let n1 = tree.get(1)
        #expect(n1?.model.properties.position == Point2D(x: 5, y: 6), "created-position")
        #expect(n1?.model.properties.opacity == 0.8, "created-opacity")
        #expect(n1?.model.content == .paint(PaintContentHandle(raw: 7)), "created-content")
        #expect(n1?.presentation.content == .paint(PaintContentHandle(raw: 7)), "created-content-mirror")
        #expect(n1?.damage.flags.content == true && n1?.damage.flags.structure == true, "created-damage")

        // --- created on existing node: bounds change bumps revision + damage ---
        var t2 = Transaction(contextId: ctx)
        var c2 = LayerCreated(nodeId: 1, kind: .container)
        c2.bounds = Bounds(w: 200, h: 80) // changed
        c2.initialContent = .none // leave content untouched
        t2.created.append(c2)
        TransactionApplier.apply(t2, to: &tree)
        let n1b = tree.get(1)
        #expect(n1b?.model.properties.bounds == Bounds(w: 200, h: 80), "recreate-bounds")
        #expect(n1b?.model.visualRevision == 1, "recreate-revision-bump")
        #expect(n1b?.model.content == .paint(PaintContentHandle(raw: 7)), "recreate-keeps-content")
        #expect(n1b?.damage.flags.backingReallocate == true, "recreate-backing-realloc")

        // --- insert: child wiring + root routing ---
        var t3 = Transaction(contextId: ctx)
        t3.created.append(LayerCreated(nodeId: 2, kind: .container))
        t3.inserted.append(LayerInserted(nodeId: 1, parentId: 0, index: 0))   // root
        t3.inserted.append(LayerInserted(nodeId: 2, parentId: 1, index: 0))   // child of 1
        TransactionApplier.apply(t3, to: &tree)
        #expect(tree.roots(for: ctx) == [1], "insert-root-routing")
        #expect(tree.get(2)?.parent == 1 && tree.get(1)?.children == [2], "insert-child")

        // Missing parents and cycles reject atomically.
        var invalid = Transaction(contextId: ctx)
        invalid.created.append(LayerCreated(nodeId: 3, kind: .container))
        invalid.inserted.append(LayerInserted(nodeId: 3, parentId: 999, index: 0))
        let missingParentResult = TransactionApplier.apply(invalid, to: &tree)
        if case let .failure(error) = missingParentResult {
            #expect(error == .insertion(nodeID: 3, parentID: 999, reason: .missingParentLayer))
        } else {
            Issue.record("missing-parent transaction unexpectedly succeeded")
        }
        #expect(tree.get(3) == nil)

        var t4 = Transaction(contextId: ctx)
        t4.inserted.append(LayerInserted(nodeId: 1, parentId: 2, index: 0))
        let cycleResult = TransactionApplier.apply(t4, to: &tree)
        if case let .failure(error) = cycleResult {
            #expect(error == .insertion(nodeID: 1, parentID: 2, reason: .layerCycle))
        } else {
            Issue.record("cyclic transaction unexpectedly succeeded")
        }
        #expect(tree.get(1)?.parent == nil && tree.roots(for: ctx).contains(1))

        // --- detach + remove ---
        var t5 = Transaction(contextId: ctx)
        t5.detached.append(LayerDetached(nodeId: 2))
        TransactionApplier.apply(t5, to: &tree)
        #expect(tree.get(2)?.parent == nil && tree.get(1)?.children == [], "detach")
        var t6 = Transaction(contextId: ctx)
        t6.removed.append(LayerRemoved(nodeId: 3))
        TransactionApplier.apply(t6, to: &tree)
        #expect(tree.get(3) == nil && !tree.roots(for: ctx).contains(3), "remove")

        // --- property update: sparse model writes ---
        var t7 = Transaction(contextId: ctx)
        var pu = LayerPropertyUpdate(nodeId: 1)
        pu.opacity = 0.25
        pu.position = Point2D(x: 11, y: 22)
        t7.propertyUpdates.append(pu)
        TransactionApplier.apply(t7, to: &tree)
        #expect(tree.get(1)?.model.properties.opacity == 0.25, "pu-opacity")
        #expect(tree.get(1)?.model.properties.position == Point2D(x: 11, y: 22), "pu-position")
        #expect(tree.get(1)?.damage.flags.property == true, "pu-damage-property")

        // bounds write resizes clip + bumps revision.
        var t8 = Transaction(contextId: ctx)
        var pu8 = LayerPropertyUpdate(nodeId: 1)
        // First install a clip, then resize via bounds.
        pu8.clip = .some(ClipOp(rect: (0, 0, 200, 80), radii: (0, 0, 0, 0), antiAlias: true,
                                transform: [1, 0, 0, 0, 1, 0, 0, 0, 1]))
        pu8.bounds = Bounds(w: 300, h: 120)
        t8.propertyUpdates.append(pu8)
        let revBefore = tree.get(1)!.model.visualRevision
        TransactionApplier.apply(t8, to: &tree)
        let clip = tree.get(1)!.model.properties.clip
        #expect(clip != nil && clip!.rect.2 == 300 && clip!.rect.3 == 120, "pu-bounds-resizes-clip")
        #expect(tree.get(1)!.model.visualRevision == revBefore + 1, "pu-bounds-revision")

        // clip clear via double-optional .some(nil).
        var t9 = Transaction(contextId: ctx)
        var pu9 = LayerPropertyUpdate(nodeId: 1)
        pu9.clip = .some(nil)
        t9.propertyUpdates.append(pu9)
        TransactionApplier.apply(t9, to: &tree)
        #expect(tree.get(1)?.model.properties.clip == nil, "pu-clip-clear")

        // --- visual style + shadow deltas ---
        var t10 = Transaction(contextId: ctx)
        var pu10 = LayerPropertyUpdate(nodeId: 1)
        var vs = VisualStyle()
        vs.backgroundColor = (1, 0, 0, 1)
        pu10.visualStyle = .set(vs)
        pu10.shadow = .set(LayerShadow(blurRadius: 4, color: (0, 0, 0, 1)))
        t10.propertyUpdates.append(pu10)
        TransactionApplier.apply(t10, to: &tree)
        let styleGot = tree.get(1)!.model.visualStyle
        #expect(styleGot != nil && float4Equal(styleGot!.backgroundColor, (1, 0, 0, 1)), "pu-style-set")
        #expect(styleGot?.shadow?.blurRadius == 4, "pu-shadow-patched-after-style")

        // re-setting the identical style is suppressed (no revision bump).
        let revBeforeNoop = tree.get(1)!.model.visualRevision
        var t11 = Transaction(contextId: ctx)
        var pu11 = LayerPropertyUpdate(nodeId: 1)
        var vsSame = vs
        vsSame.shadow = LayerShadow(blurRadius: 4, color: (0, 0, 0, 1)) // matches current
        pu11.visualStyle = .set(vsSame)
        t11.propertyUpdates.append(pu11)
        TransactionApplier.apply(t11, to: &tree)
        #expect(tree.get(1)!.model.visualRevision == revBeforeNoop, "pu-style-noop-suppressed")

        // shadow on a styleless layer creates a default style.
        var tree2 = LayerTree()
        tree2.insertLayer(Layer(id: 50, kind: .container))
        var t12 = Transaction(contextId: ctx)
        var pu12 = LayerPropertyUpdate(nodeId: 50)
        pu12.shadow = .set(LayerShadow(blurRadius: 2, color: (0, 0, 0, 1)))
        t12.propertyUpdates.append(pu12)
        TransactionApplier.apply(t12, to: &tree2)
        #expect(tree2.get(50)?.model.visualStyle?.shadow?.blurRadius == 2, "pu-shadow-creates-style")

        // --- content delta + mirror, same-handle suppression ---
        var t13 = Transaction(contextId: ctx)
        var pu13 = LayerPropertyUpdate(nodeId: 50)
        pu13.content = .external(IOSurfaceID(raw: 9))
        t13.propertyUpdates.append(pu13)
        TransactionApplier.apply(t13, to: &tree2)
        #expect(tree2.get(50)?.model.content == .external(IOSurfaceID(raw: 9)) &&
              tree2.get(50)?.presentation.content == .external(IOSurfaceID(raw: 9)), "pu-content-mirror")
        let revAfterContent = tree2.get(50)!.model.visualRevision
        var t14 = Transaction(contextId: ctx)
        var pu14 = LayerPropertyUpdate(nodeId: 50)
        pu14.content = .external(IOSurfaceID(raw: 9)) // same → suppressed
        t14.propertyUpdates.append(pu14)
        TransactionApplier.apply(t14, to: &tree2)
        #expect(tree2.get(50)!.model.visualRevision == revAfterContent, "pu-content-same-suppressed")
        // clearing content resets the content sample.
        var t15 = Transaction(contextId: ctx)
        var pu15 = LayerPropertyUpdate(nodeId: 50)
        pu15.content = .none
        t15.propertyUpdates.append(pu15)
        TransactionApplier.apply(t15, to: &tree2)
        #expect(tree2.get(50)?.model.content == LayerContent.none &&
              tree2.get(50)?.presentation.contentSample == ContentSample(), "pu-content-clear-resets-sample")

        // --- compound frame ---
        var t16 = Transaction(contextId: ctx)
        var pu16 = LayerPropertyUpdate(nodeId: 50)
        pu16.frame = Frame(left: 10, top: 20, right: 110, bottom: 70)
        t16.propertyUpdates.append(pu16)
        TransactionApplier.apply(t16, to: &tree2)
        #expect(tree2.get(50)?.model.properties.position == Point2D(x: 10, y: 20), "pu-frame-position")
        #expect(tree2.get(50)?.model.properties.bounds == Bounds(w: 100, h: 50), "pu-frame-bounds")
    }
}
