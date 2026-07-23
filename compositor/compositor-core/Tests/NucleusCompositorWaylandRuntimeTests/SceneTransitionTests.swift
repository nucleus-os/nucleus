import Testing
import NucleusLayers
import NucleusCompositorServer
import NucleusCompositorWindowScene
@testable import NucleusCompositorWaylandRuntime

/// Release transition gate. Snapshot and mutation bounds are exact ownership
/// counts and do not depend on frame duration or machine throughput.
@Suite(.serialized)
struct NucleusCompositorTransitionStressTests {

@MainActor
@Test func firstMapPublishesAlreadyImportedRootContent() {
    let graph = WaylandTestGraph()
    let sink = InMemoryCommitSink()
    let author = WindowSceneAuthor(commitSinkFactory: { sink })
    let feeder = SceneFeeder(author: author, host: graph.host)
    let sample = ContentSample(
        sourceSurfaceID: 76,
        srcWidth: 1280,
        srcHeight: 720,
        logicalWidth: 1280,
        logicalHeight: 720)

    feeder.windowMapped(
        surfaceID: 76,
        x: 20,
        y: 30,
        width: 1280,
        height: 748,
        iosurfaceID: 42,
        sample: sample)

    let contentUpdates = sink.transactions
        .flatMap(\.propertyUpdates)
        .compactMap(\.properties.content)
    let sampleUpdates = sink.transactions
        .flatMap(\.propertyUpdates)
        .compactMap(\.properties.contentSample)
    #expect(contentUpdates.contains(
        LayerContent(kind: .external, handle: 42)))
    #expect(sampleUpdates.contains(sample))
}

@MainActor
@Test func closingTransitionRetainsSnapshotAndDestroysExactlyOnce() throws {
    let graph = WaylandTestGraph()
    let server = graph.server

    let sink = InMemoryCommitSink()
    let author = WindowSceneAuthor(commitSinkFactory: { sink })
    let renderService = RenderServiceSpy()
    let feeder = SceneFeeder(
        author: author,
        host: graph.host,
        renderService: renderService)

    let window = server.createWindow(source: .xdg, id: 9001)
    window.surfaceObjectId = 77
    window.committedLogicalSize = RenderSize(w: 640, h: 480)
    window.committedBufferSize = RenderSize(w: 640, h: 480)
    window.setGeometry(
        WindowRect(x: 20, y: 30, width: 640, height: 480))
    window.seedPresentationActorToRect(
        PresentationRect(x: 20, y: 30, w: 640, h: 480),
        slotGeneration: 1)
    window.mapped = true
    feeder.windowMapped(
        surfaceID: 77,
        x: 20,
        y: 30,
        width: 640,
        height: 480)
    feeder.surfaceContent(surfaceID: 77, iosurfaceID: 9)

    #expect(feeder.beginClosing(
        window: window,
        iosurfaceID: 9,
        destroyWindowOnCompletion: false))
    #expect(renderService.capturedSnapshotIOSurfaceIDs == [9])
    #expect(renderService.liveSnapshotCount == 1)
    // A newer client buffer may replace the live backing, but the overlay remains
    // the immutable capture from the close boundary.
    feeder.surfaceContent(surfaceID: 77, iosurfaceID: 99)
    #expect(renderService.capturedSnapshotIOSurfaceIDs == [9])
    window.mapped = false

    // Role destruction upgrades the same immutable transition. It neither
    // recaptures nor creates a second generation.
    let generation = try #require(window.activeTransitionGeneration())
    #expect(feeder.beginClosing(
        window: window,
        iosurfaceID: 9,
        destroyWindowOnCompletion: true))
    #expect(window.activeTransitionGeneration() == generation)
    #expect(renderService.capturedSnapshotIOSurfaceIDs == [9])

    #expect(feeder.authorFrame(
        outputID: 1,
        predictedPresentNs: 10_000_000_000))
    #expect(feeder.authorFrame(
        outputID: 1,
        predictedPresentNs: 10_090_000_000))
    #expect(abs(window.windowPresentationOpacity() - 0.5) < 0.001)
    #expect(!feeder.authorFrame(
        outputID: 1,
        predictedPresentNs: 10_180_000_000))

    #expect(server.window(id: 9001) == nil)
    #expect(renderService.releasedSnapshotHandles == [1_009])
    #expect(renderService.liveSnapshotCount == 0)
    #expect(feeder.transitionMetrics == .init(
        acceptedRemovals: 1,
        snapshotRetirements: 1))
    #expect(window.takePresentationTransition(
        generation: generation) == nil)

    let snapshotCreates = sink.transactions
        .flatMap(\.created)
        .filter { $0.1.initialContent.kind == .snapshot }
    #expect(snapshotCreates.count == 1)
    #expect(snapshotCreates.first?.1.initialContent.handle == 1_009)
    #expect(sink.transactions.flatMap(\.removed).count > 0)
}

@MainActor
@Test func secondTileAtomicallySupersedesAndRetiresFirstSnapshot() throws {
    let graph = WaylandTestGraph()
    let server = graph.server

    let sink = InMemoryCommitSink()
    let author = WindowSceneAuthor(commitSinkFactory: { sink })
    let renderService = RenderServiceSpy()
    let feeder = SceneFeeder(
        author: author,
        host: graph.host,
        renderService: renderService)
    let window = server.createWindow(source: .xdg, id: 9002)
    window.surfaceObjectId = 78
    window.committedLogicalSize = RenderSize(w: 400, h: 300)
    window.committedBufferSize = RenderSize(w: 400, h: 300)
    window.setGeometry(
        WindowRect(x: 0, y: 0, width: 400, height: 300))
    window.seedPresentationActorToRect(
        PresentationRect(x: 0, y: 0, w: 400, h: 300),
        slotGeneration: 1)
    window.mapped = true
    feeder.windowMapped(
        surfaceID: 78,
        x: 0,
        y: 0,
        width: 400,
        height: 300)
    feeder.surfaceContent(surfaceID: 78, iosurfaceID: 9)

    feeder.beginTileTransition(
        window: window,
        finalRect: PresentationRect(x: 0, y: 0, w: 800, h: 600),
        slotGeneration: 2,
        iosurfaceID: 9)
    let firstGeneration = try #require(
        window.activeTransitionGeneration())
    #expect(renderService.liveSnapshotCount == 1)
    #expect(feeder.authorFrame(
        outputID: 1,
        predictedPresentNs: 20_000_000_000))
    #expect(feeder.authorFrame(
        outputID: 1,
        predictedPresentNs: 20_050_000_000))

    feeder.beginTileTransition(
        window: window,
        finalRect: PresentationRect(x: 100, y: 50, w: 600, h: 450),
        slotGeneration: 3,
        iosurfaceID: 10)
    let secondGeneration = try #require(
        window.activeTransitionGeneration())
    #expect(secondGeneration != firstGeneration)
    #expect(renderService.capturedSnapshotIOSurfaceIDs == [9, 10])
    #expect(renderService.releasedSnapshotHandles == [1_009])
    #expect(renderService.liveSnapshotCount == 1)
    #expect(window.takePresentationTransition(
        generation: firstGeneration) == nil)

    window.committedLogicalSize = RenderSize(w: 600, h: 450)
    var predicted = UInt64(20_100_000_000)
    var inFlight = true
    while inFlight {
        inFlight = feeder.authorFrame(
            outputID: 1,
            predictedPresentNs: predicted)
        predicted += 50_000_000
        #expect(predicted < 22_000_000_000)
    }
    #expect(window.activeTransitionGeneration() == nil)
    #expect(renderService.releasedSnapshotHandles == [1_009, 1_010])
    #expect(renderService.liveSnapshotCount == 0)
    #expect(feeder.transitionMetrics == .init(
        acceptedRemovals: 1,
        snapshotRetirements: 2))

    let replacementTransactions = sink.transactions.filter {
        $0.created.contains {
            $0.1.initialContent.kind == .snapshot
                && $0.1.initialContent.handle == 1_010
        }
    }
    #expect(replacementTransactions.count == 1)
    #expect(replacementTransactions.first?.removed.count == 1)
}

@MainActor
@Test func sessionLockCancellationRetiresTileSnapshotAndMotion() {
    let graph = WaylandTestGraph()
    let server = graph.server

    let author = WindowSceneAuthor(
        commitSinkFactory: { InMemoryCommitSink() })
    let renderService = RenderServiceSpy()
    let feeder = SceneFeeder(
        author: author,
        host: graph.host,
        renderService: renderService)
    let window = server.createWindow(source: .xdg, id: 9003)
    window.surfaceObjectId = 79
    window.committedLogicalSize = RenderSize(w: 400, h: 300)
    window.committedBufferSize = RenderSize(w: 400, h: 300)
    window.setGeometry(
        WindowRect(x: 0, y: 0, width: 400, height: 300))
    window.seedPresentationActorToRect(
        PresentationRect(x: 0, y: 0, w: 400, h: 300),
        slotGeneration: 1)
    window.mapped = true
    feeder.windowMapped(
        surfaceID: 79,
        x: 0,
        y: 0,
        width: 400,
        height: 300)

    feeder.beginTileTransition(
        window: window,
        finalRect: PresentationRect(x: 0, y: 0, w: 800, h: 600),
        slotGeneration: 2,
        iosurfaceID: 12)
    #expect(window.hasActiveTileAnimation())
    #expect(window.activeTransitionGeneration() != nil)

    feeder.cancelTransitionsForSessionLock()

    #expect(!window.hasActiveTileAnimation())
    #expect(window.activeTransitionGeneration() == nil)
    #expect(renderService.releasedSnapshotHandles == [1_012])
    #expect(renderService.liveSnapshotCount == 0)
    #expect(feeder.transitionMetrics == .init(
        acceptedRemovals: 1,
        snapshotRetirements: 1))
    #expect(window.mapped)

    feeder.beginTileTransition(
        window: window,
        finalRect: PresentationRect(x: 10, y: 10, w: 700, h: 500),
        slotGeneration: 3,
        iosurfaceID: 13)
    #expect(renderService.liveSnapshotCount == 1)
    feeder.shutdown()
    #expect(renderService.releasedSnapshotHandles == [1_012, 1_013])
    #expect(renderService.liveSnapshotCount == 0)
    #expect(feeder.transitionMetrics == .init(
        acceptedRemovals: 2,
        snapshotRetirements: 2))
}

}
