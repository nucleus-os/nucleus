import Testing
@testable import NucleusCompositorWaylandRuntime

@MainActor
@Suite struct SubsurfaceTopologyTests {
    private func surface(_ compositor: WlCompositor, graph: WaylandTestGraph) -> WlSurface {
        graph.surface(compositor: compositor)
    }

    @Test func positionAndStackApplyOnlyWithParentCommit() {
        let graph = WaylandTestGraph()
        let compositor = graph.compositor()
        let parent = surface(compositor, graph: graph)
        let first = surface(compositor, graph: graph)
        let second = surface(compositor, graph: graph)
        #expect(first.claimSubsurfaceRole())
        #expect(second.claimSubsurfaceRole())
        first.attachAsSubsurface(to: parent)
        second.attachAsSubsurface(to: parent)
        first.setSubsurfacePosition(x: 12, y: 34)

        #expect(parent.subsurfaceChildren.isEmpty)
        #expect(first.subsurfaceX == 0)
        parent.commit()
        #expect(parent.subsurfaceChildren.count == 2)
        #expect(parent.subsurfaceChildren[0] === first)
        #expect(parent.subsurfaceChildren[1] === second)
        #expect(first.subsurfaceX == 12)
        #expect(first.subsurfaceY == 34)

        #expect(parent.placeChild(
            second, relativeTo: first, .below))
        #expect(parent.subsurfaceChildren[0] === first)
        parent.commit()
        #expect(parent.subsurfaceChildren[0] === second)
        #expect(parent.subsurfaceChildren[1] === first)
    }

    @Test func ancestryCycleAndInheritedSynchronizationAreExplicit() {
        let graph = WaylandTestGraph()
        let compositor = graph.compositor()
        let root = surface(compositor, graph: graph)
        let child = surface(compositor, graph: graph)
        let grandchild = surface(compositor, graph: graph)
        #expect(child.claimSubsurfaceRole())
        #expect(grandchild.claimSubsurfaceRole())
        child.attachAsSubsurface(to: root)
        grandchild.attachAsSubsurface(to: child)

        #expect(root.wouldCreateSubsurfaceCycle(parent: grandchild))
        #expect(child.wouldCreateSubsurfaceCycle(parent: child))
        #expect(grandchild.isEffectivelySync)

        grandchild.setSubsurfaceSync(false)
        #expect(grandchild.isEffectivelySync)
        child.setSubsurfaceSync(false)
        #expect(!grandchild.isEffectivelySync)
    }
}
