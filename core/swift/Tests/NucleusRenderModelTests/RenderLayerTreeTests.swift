@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderLayerTreeTests {
    @Test func renderLayerTree() {
        // InvalidationFlags.any().
        #expect(!InvalidationFlags.none.any(), "flags-none")
        var f = InvalidationFlags.none
        f.content = true
        #expect(f.any(), "flags-any")

        // Node defaults + effective accessors fall through to the model.
        var node = Layer(id: 1, kind: .container)
        node.model.properties.opacity = 0.5
        node.model.properties.position = Point2D(x: 3, y: 4)
        #expect(node.effectiveOpacity() == 0.5, "node-eff-opacity-model")
        #expect(node.effectivePosition() == Point2D(x: 3, y: 4), "node-eff-position-model")
        var ov = PresentationOverride()
        ov.opacity = 0.1
        node.presentation.override_ = ov
        #expect(node.effectiveOpacity() == 0.1, "node-eff-opacity-override")

        // contributesOwnExtent: a bare container with no content does not.
        #expect(!node.contributesOwnExtent(), "extent-container-none")
        // A container with content does.
        node.presentation.content = .paint(PaintContentHandle(raw: 9))
        #expect(node.contributesOwnExtent(), "extent-content")
        // A backdrop kind contributes regardless of content.
        var bd = Layer(id: 2, kind: .backdrop(BackdropKindParams(shape: .rect((0, 0, 1, 1)))))
        #expect(bd.contributesOwnExtent(), "extent-backdrop-kind")
        // A visual style contributes.
        bd = Layer(id: 2, kind: .container)
        bd.model.visualStyle = VisualStyle()
        #expect(bd.contributesOwnExtent(), "extent-visual-style")
        // Tree: insert + get.
        var tree = LayerTree()
        tree.insertLayer(Layer(id: 10, kind: .container))
        tree.insertLayer(Layer(id: 11, kind: .container))
        tree.insertLayer(Layer(id: 12, kind: .container))
        #expect(tree.get(10) != nil && tree.get(99) == nil, "tree-insert-get")

        // attachRoot orders by index; clamps past the end.
        try! tree.attachRoot(10, index: 0, contextId: compositorContextId)
        try! tree.attachRoot(11, index: 99, contextId: compositorContextId)
        try! tree.attachRoot(12, index: 1, contextId: compositorContextId)
        #expect(tree.roots(for: compositorContextId) == [10, 12, 11], "tree-attach-root-order")

        // Missing node → error.
        var rootThrew = false
        do { try tree.attachRoot(999, index: 0, contextId: compositorContextId) } catch { rootThrew = true }
        #expect(rootThrew, "tree-attach-root-missing-throws")

        // attachChild re-parents (and detaches from the root list).
        try! tree.attachChild(parentId: 10, childId: 11, index: 0)
        #expect(tree.get(11)?.parent == 10 && tree.get(10)?.children == [11], "tree-attach-child")
        #expect(tree.roots(for: compositorContextId) == [10, 12], "tree-attach-child-detaches-root")

        // Cycle refusal: 11 is a child of 10, so 10 under 11 would cycle.
        #expect(tree.wouldCreateCycle(childId: 10, parentId: 11), "tree-cycle-detected")
        var cycleThrew = false
        do { try tree.attachChild(parentId: 11, childId: 10, index: 0) } catch LayerTreeError.layerCycle {
            cycleThrew = true
        } catch { }
        #expect(cycleThrew, "tree-attach-child-cycle-throws")
        // Self-parenting is a cycle.
        #expect(tree.wouldCreateCycle(childId: 5, parentId: 5), "tree-self-cycle")

        // detach removes from parent + clears parent pointer.
        tree.detach(11)
        #expect(tree.get(11)?.parent == nil && tree.get(10)?.children == [], "tree-detach")

        // removeLayer detaches then drops the node.
        try! tree.attachChild(parentId: 10, childId: 12, index: 0)
        tree.removeLayer(12)
        #expect(tree.get(12) == nil && tree.get(10)?.children == [], "tree-remove")
        // root list no longer references a removed root node.
        tree.removeLayer(10)
        #expect(tree.get(10) == nil && tree.roots(for: compositorContextId) == [], "tree-remove-root")

        // Removing a non-empty parent removes the complete subtree; no child can
        // retain a dangling parent id.
        var subtree = LayerTree()
        subtree.insertLayer(Layer(id: 20, kind: .container))
        subtree.insertLayer(Layer(id: 21, kind: .container))
        subtree.insertLayer(Layer(id: 22, kind: .container))
        try! subtree.attachRoot(20, index: 0, contextId: compositorContextId)
        try! subtree.attachChild(parentId: 20, childId: 21, index: 0)
        try! subtree.attachChild(parentId: 21, childId: 22, index: 0)
        subtree.removeLayer(20)
        #expect(subtree.layers.isEmpty)
        #expect(subtree.roots(for: compositorContextId).isEmpty)
    }
}
