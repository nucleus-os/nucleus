import Testing
@testable import NucleusCompositorWaylandRuntime

@MainActor
@Suite struct SurfaceTransactionTests {
    private let graph = WaylandTestGraph()
    private final class Observer: WlSurfaceCommitObserver {
        var pendingValue: Int?
        var applied: [Int] = []

        func captureSurfaceCommit(
            _ surface: WlSurface,
            bufferAttached: Bool,
            attachedBufferIsNonNull: Bool,
            attachedBufferSupportsExplicitSync: Bool,
            aux: inout SurfaceAuxState,
            effects: inout [() -> Void]
        ) -> Bool {
            guard let value = pendingValue else { return true }
            pendingValue = nil
            effects.append { [weak self] in self?.applied.append(value) }
            return true
        }
    }

    private final class ReentrantReadObserver: WlSurfaceCommitObserver {
        var observedDestination: WlSize?

        func captureSurfaceCommit(
            _ surface: WlSurface,
            bufferAttached: Bool,
            attachedBufferIsNonNull: Bool,
            attachedBufferSupportsExplicitSync: Bool,
            aux: inout SurfaceAuxState,
            effects: inout [() -> Void]
        ) -> Bool {
            effects.append {
                self.observedDestination = surface.aux.viewportDestination
            }
            return true
        }
    }

    private func synchronizedPair() -> (
        parent: WlSurface,
        child: WlSurface
    ) {
        let compositor = graph.compositor()
        let parent = graph.surface(compositor: compositor)
        let child = graph.surface(compositor: compositor)
        #expect(child.claimSubsurfaceRole())
        child.attachAsSubsurface(to: parent)
        return (parent, child)
    }

    @Test func uncommittedObserverStateCannotLeakIntoCachedCommit() {
        let pair = synchronizedPair()
        let observer = Observer()
        pair.child.addCommitObserver(observer)

        observer.pendingValue = 1
        pair.child.commit()
        observer.pendingValue = 2
        pair.parent.commit()

        #expect(observer.applied == [1])

        pair.child.commit()
        pair.parent.commit()
        #expect(observer.applied == [1, 2])
    }

    @Test func supersededCachedTransactionDiscardsItsEffects() {
        let pair = synchronizedPair()
        let observer = Observer()
        pair.child.addCommitObserver(observer)

        observer.pendingValue = 1
        pair.child.commit()
        observer.pendingValue = 2
        pair.child.commit()
        pair.parent.commit()

        #expect(observer.applied == [2])
    }

    @Test func appliedEffectCanReenterCommittedAuxiliaryState() {
        let compositor = graph.compositor()
        let surface = graph.surface(compositor: compositor)
        let observer = ReentrantReadObserver()
        surface.addCommitObserver(observer)
        surface.setPendingViewportDestination(WlSize(width: 640, height: 480))

        surface.commit()

        #expect(observer.observedDestination == WlSize(width: 640, height: 480))
        #expect(surface.aux.viewportDestination == observer.observedDestination)
    }
}
