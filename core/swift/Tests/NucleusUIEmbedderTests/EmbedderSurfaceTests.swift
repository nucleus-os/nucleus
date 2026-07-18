import Testing
import NucleusUI
import NucleusUIEmbedder
import NucleusLayers
import NucleusTypes

/// `NucleusUIEmbedder` is almost entirely forwarders over `package` members of
/// NucleusUI, which makes it vulnerable to one specific failure: a public
/// forwarder whose name and signature match the member it forwards to calls
/// *itself*. That compiles, and it dies at run time with a stack overflow.
///
/// It happened here — the first `publish(placing:includes:)` shadowed the
/// method it meant to call, and only a compositor test caught it. These
/// exercise each forwarder so the next one is caught in this module.
@MainActor
@Suite struct EmbedderSurfaceTests {
    private func makeContext(_ id: UInt32) throws -> (Context, InMemoryCommitSink) {
        let sink = InMemoryCommitSink()
        return (try Context(id: ContextID(rawValue: id), commitSink: sink), sink)
    }

    @Test func publishingThroughTheEmbedderDoesNotRecurse() throws {
        let sink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 900), commitSink: sink)
        let scene = publication.makeWindowScene(windows: [])

        // The regression: this used to overflow the stack rather than return.
        let published = try scene.publish()
        #expect(published.visualContent.isEmpty)
    }

    @Test func publishingInterleavesPlacementsWithWindows() throws {
        installStubHost()
        let sink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 901), commitSink: sink)
        let window = EmbedderApplication.withContext(publication.visualContext) { () -> Window in
            let window = Window(title: "Native")
            let root = View()
            root.frame = Rect(x: 0, y: 0, width: 100, height: 20)
            // A view with nothing to draw publishes no visual content, so give
            // it a background — otherwise this asserts on an empty scene.
            root.backgroundColor = Color(1, 1, 1, 1)
            window.setContentView(root)
            window.orderFront()
            return window
        }
        let scene = publication.makeWindowScene(windows: [window])

        let published = try scene.publish(placing: [
            ScenePlacement(id: 77, rootLayerID: 770, level: .overlay),
        ])
        #expect(published.visualContent.count == 2)
        #expect(published.visualContent.map(\.orderIndex) == [0, 1])
        #expect(published.visualContent.last?.id == 77, "the overlay placement sorts last")
    }

    @Test func aSceneRootIsCreatedOnceAndReused() throws {
        let sink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 902), commitSink: sink)
        let scene = publication.makeWindowScene(windows: [])

        let first = try scene.attachedRootLayer()
        let second = try scene.attachedRootLayer()
        #expect(first.id == second.id)
    }

    @Test func sublayerIndexRisesWithLevel() throws {
        installStubHost()
        let sink = InMemoryCommitSink()
        let publication = try WindowScenePublicationContext(
            visualContextID: ContextID(rawValue: 903), commitSink: sink)
        let window = EmbedderApplication.withContext(publication.visualContext) { () -> Window in
            let window = Window(title: "Native")
            let root = View()
            root.frame = Rect(x: 0, y: 0, width: 100, height: 20)
            root.backgroundColor = Color(1, 1, 1, 1)
            window.setContentView(root)
            window.orderFront()
            return window
        }
        let scene = publication.makeWindowScene(windows: [window])
        #expect(scene.sublayerIndex(forLevel: .overlay) >= scene.sublayerIndex(forLevel: .normal))
    }

    @Test func recordingAndRegisteringADrawingRoundTrips() throws {
        installStubHost()
        let (context, _) = try makeContext(904)

        let graphics = GraphicsContext.makeEmbedderContext()
        graphics.fillColor = Color(1, 0, 0, 1)
        graphics.fill(Rect(x: 0, y: 0, width: 10, height: 10))

        let recording = graphics.recordedDrawing
        #expect(recording.paintCommands.count == 1)
        #expect(!recording.isEmptyDrawing)

        let registered = try registerPaint(recording, width: 10, height: 10, in: context)
        #expect(registered.update.content != nil)
    }

    @Test func aViewsRecordedDrawingIsReadableThroughTheEmbedder() throws {
        installStubHost()
        let (context, _) = try makeContext(905)
        let view = EmbedderApplication.withContext(context) { () -> View in
            let view = View()
            view.frame = Rect(x: 0, y: 0, width: 20, height: 10)
            view.backgroundColor = Color(0, 1, 0, 1)
            return view
        }
        view.displayIfNeeded()
        #expect(view.recordedDrawing.paintCommands.count == 1)
        #expect(view.embedderBackingLayer.context === context)
    }

    /// Binding must apply locally *and* append ambiently; a caller that only
    /// applied would leave the compositor's committed state stale.
    @Test func bindingAppliesAndAppendsTheUpdate() throws {
        installStubHost()
        let (context, sink) = try makeContext(906)
        let view = EmbedderApplication.withContext(context) { () -> View in
            let view = View()
            view.frame = Rect(x: 0, y: 0, width: 20, height: 10)
            view.backgroundColor = Color(0, 0, 1, 1)
            return view
        }
        view.displayIfNeeded()

        let layer = view.embedderBackingLayer
        let registered = try registerPaint(
            view.recordedDrawing, width: 20, height: 10, in: context)
        registered.bind(to: layer)
        try LayerTransaction.flushImplicit(in: context)

        #expect(!sink.transactions.isEmpty, "the update reached the sink")
    }
}
