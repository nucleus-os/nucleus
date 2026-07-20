import Testing
import NucleusUI
import NucleusUIEmbedder
@_spi(NucleusCompositor) import NucleusLayers
@testable import NucleusCompositorOverlay

/// Hosted surfaces are compositor vocabulary, so their tests live with them.
/// They moved here from `NucleusUITests` when the type did: nothing outside the
/// compositor has the concept, and the UI framework now vends only the generic
/// `ScenePlacement` seam these map onto.
@MainActor
@Suite(.uiContext) struct HostedSurfaceTests {
    @Test func windowSceneAttachesHostedSurfaceThroughSceneRoot() throws {
        let visualSink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 720), commitSink: visualSink)
        let visualContext = publication.visualContext
        let scene = publication.makeWindowScene(windows: [])
        let registry = HostedSurfaceRegistry<String>(
            context: visualContext,
            uiContext: publication.semanticContext)
        let surface = registry.surface(
            for: "dock", frame: Rect(x: 0, y: 0, width: 100, height: 80))

        let attachedSurfaceID = try registry.attach(surface, in: scene) { rootView, surfaceID, parentLayer, _ in
            #expect(rootView === surface.rootView)
            #expect(surfaceID == surface.surfaceID)
            #expect(parentLayer.context === visualContext)
            return surfaceID
        }

        #expect(attachedSurfaceID == surface.surfaceID)
        #expect(surface.hasCommittedContent)
        #expect(surface.commitsFrameUpdates)
        let rootInsertTransaction = try #require(visualSink.transactions.first)
        #expect(rootInsertTransaction.inserted.contains {
            $0.parent == nil
        })
    }

    @Test func windowSceneBatchAttachesHostedSurfacesThroughOneSceneRoot() throws {
        let visualSink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 721), commitSink: visualSink)
        let scene = publication.makeWindowScene(windows: [])
        let registry = HostedSurfaceRegistry<String>(
            context: publication.visualContext,
            uiContext: publication.semanticContext)
        let dock = registry.surface(for: "dock")
        let menuBar = registry.surface(for: "menubar")
        var attachedIDs: [Int] = []

        let didAttach = try registry.attachAll(registry.surfaces, in: scene) { surface in
            surface === dock
        } using: { _, surfaceID, _, _ in
            attachedIDs.append(surfaceID)
        }

        #expect(didAttach)
        #expect(attachedIDs == [dock.surfaceID])
        #expect(dock.hasCommittedContent)
        #expect(!menuBar.hasCommittedContent)
        #expect(visualSink.transactions.count == 2)
    }

    @Test func hostedSurfaceOwnsGenericRootLifecycleAndFrameUpdates() throws {
        let visualSink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 718), commitSink: visualSink)
        let visualContext = publication.visualContext
        let scene = publication.makeWindowScene(windows: [])
        let registry = HostedSurfaceRegistry<String>(
            context: visualContext,
            uiContext: publication.semanticContext,
            firstSurfaceID: 9
        )
        let surface = registry.surface(
            for: "surface",
            frame: Rect(x: 0, y: 0, width: 100, height: 80)
        )

        #expect(surface.surfaceID == 9)
        #expect(surface.frame == Rect(x: 0, y: 0, width: 100, height: 80))
        #expect(surface.visualRootLayer.frame == GeometryRect(x: 0, y: 0, width: 100, height: 80))
        #expect(!surface.hasCommittedContent)
        #expect(!surface.commitsFrameUpdates)

        try registry.attach(surface, in: scene) { _, _, _, _ in }
        surface.updateFrame(Rect(x: 0, y: 0, width: 320, height: 200))

        try LayerTransaction.flushImplicit(in: visualContext)
        #expect(surface.hasCommittedContent)
        #expect(surface.commitsFrameUpdates)
        #expect(surface.frame == Rect(x: 0, y: 0, width: 320, height: 200))
        #expect(visualSink.transactions.contains { transaction in
            transaction.propertyUpdates.contains {
                $0.layer == surface.visualRootLayer.id &&
                    $0.properties.position == GeometryPoint(x: 0, y: 0) &&
                    $0.properties.bounds == GeometrySize(width: 320, height: 200)
            }
        })

        try surface.detach()
        #expect(!surface.hasCommittedContent)
        #expect(!surface.commitsFrameUpdates)
        #expect(visualSink.transactions.contains { transaction in
            transaction.removed.contains(surface.visualRootLayer.id)
        })
    }

    @Test func hostedSurfaceRegistryOwnsStableIDsOrderingAndVisualContent() throws {
        let visualSink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 719), commitSink: visualSink)
        let registry = HostedSurfaceRegistry<String>(
            context: publication.visualContext,
            uiContext: publication.semanticContext)
        let scene = publication.makeWindowScene(windows: [])

        let dock = registry.surface(for: "dock", frame: Rect(x: 0, y: 0, width: 100, height: 40))
        let menuBar = registry.surface(for: "menubar")
        let repeatedDock = registry.surface(for: "dock")

        #expect(dock === repeatedDock)
        #expect(dock.surfaceID == 1)
        #expect(menuBar.surfaceID == 2)
        #expect(registry.surfaceID(for: "dock") == 1)
        #expect(registry.surfaces.map(\.surfaceID) == [1, 2])

        _ = try registry.attachAll(
            registry.surfaces,
            in: scene,
            where: { _ in true },
            using: { _, _, _, _ in }
        )
        registry.updateFrame(Rect(x: 0, y: 0, width: 320, height: 200))

        let visualContent = registry.placements()
        #expect(visualContent.map(\.id) == [1, 2])
        #expect(visualContent.map(\.rootLayerID) == [
            dock.visualRootLayer.id.rawValue,
            menuBar.visualRootLayer.id.rawValue,
        ])
        #expect(visualContent.allSatisfy { $0.visible })
        #expect(dock.frame == Rect(x: 0, y: 0, width: 320, height: 200))
        #expect(menuBar.frame == Rect(x: 0, y: 0, width: 320, height: 200))

        try registry.detachSurface("dock")
        #expect(registry.surfaceID(for: "dock") == nil)
        #expect(registry.surfaces.map(\.surfaceID) == [2])
        #expect(registry.placements().map(\.id) == [2])
        #expect(visualSink.transactions.contains { transaction in
            transaction.removed.contains(dock.visualRootLayer.id)
        })
    }

    @Test func compositorEmbeddedAdapterPublishesReparentsAndTearsDownOneScene()
        throws
    {
        installStubHost()
        let sink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 722),
            commitSink: sink)
        let (window, left, right, label) =
            publication.withSemanticContext {
                let window = Window(title: "Overlay")
                let root = View()
                root.frame = Rect(x: 0, y: 0, width: 240, height: 80)
                let left = View()
                let right = View()
                let label = Label("retained")
                label.frame = Rect(x: 4, y: 4, width: 80, height: 24)
                root.addSubview(left)
                root.addSubview(right)
                left.addSubview(label)
                window.setContentView(root)
                window.orderFront()
                return (window, left, right, label)
            }
        let scene = publication.makeWindowScene(windows: [window])

        _ = try scene.publish()
        let acceptedLayerCount = publication.visualContext.layers.count
        #expect(acceptedLayerCount >= 5)

        label.isHidden = true
        _ = try scene.publish()
        #expect(sink.transactions.last?.propertyUpdates.contains {
            $0.properties.opacity == 0
        } == true)

        label.isHidden = false
        right.addSubview(label)
        _ = try scene.publish()
        #expect(sink.transactions.last?.inserted.count == 1)
        #expect(publication.visualContext.layers.count == acceptedLayerCount)
        withExtendedLifetime(left) {}

        try scene.disconnect()
        #expect(scene.windows.isEmpty)
        #expect(publication.visualContext.layers.isEmpty)
        #expect(sink.transactions.last?.removed.isEmpty == false)
    }

}
