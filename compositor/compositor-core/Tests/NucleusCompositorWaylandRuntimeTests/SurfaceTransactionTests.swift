import Testing
@testable import NucleusCompositorWaylandRuntime

@MainActor
@Suite struct SurfaceTransactionTests {
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

    private func synchronizedPair() -> (
        parent: WlSurface,
        child: WlSurface
    ) {
        let compositor = WlCompositor()
        let parent = WlSurface(compositor: compositor, version: 7)
        let child = WlSurface(compositor: compositor, version: 7)
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
}
