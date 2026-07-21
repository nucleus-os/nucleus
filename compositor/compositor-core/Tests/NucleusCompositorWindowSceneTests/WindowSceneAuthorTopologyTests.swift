import NucleusLayers
import NucleusRenderHost
import NucleusRenderModel
import Testing
import NucleusCompositorWindowScene

// Behavioral coverage for the compositor-root self-hosting topology that the
// scene feeder drives at the Wayland cutover (`WindowSceneAuthor.ensureCompositorRoot`
// / `hostContextInRoot` / `setWindowOrder` / the self-allocating `surfaceAttached`
// / `surfaceDestroyed`). These paths are otherwise exercised only at the swap —
// this pins the layer-tree shape they emit so a regression surfaces here, not in
// the live compositor.
//
// The author is driven through an injected `InMemoryCommitSink` per context (the
// `commitSinkFactory`), so assertions read the real encoded transactions — no
// production `HostCommitSink`, no C round-trip, no stubbed commit path. A stub
// layers host supplies the context-id allocator the self-allocating attach needs.

/// Hands the author a fresh capturing sink per `Context` and retains them so the
/// test can read back every committed transaction across all contexts.
@MainActor
final class SinkRegistry {
    private(set) var sinks: [InMemoryCommitSink] = []

    func make() -> InMemoryCommitSink {
        let sink = InMemoryCommitSink()
        sinks.append(sink)
        return sink
    }

    /// The compositor-root context's sink — always the first one minted
    /// (`ensureCompositorRoot` runs before any window context is created).
    var rootSink: InMemoryCommitSink? { sinks.first }

    var allTransactions: [EncodedTransaction] { sinks.flatMap(\.transactions) }

    func created(context id: NucleusLayers.ContextID) -> [(LayerID, LayerDescriptor)] {
        allTransactions.filter { $0.contextID == id }.flatMap(\.created)
    }
}

@MainActor
final class RejectingCommitSink: CommitSink {
    let resourceHostHandle: UInt64 = 0
    let runtimeHost = LayerRuntimeHost.inMemory()
    private(set) var transactions: [EncodedTransaction] = []
    var rejectNext = false

    func commit(_ transaction: EncodedTransaction) throws(LayerError) {
        if rejectNext {
            rejectNext = false
            throw .backendFailure(detail: "fixture rejection")
        }
        transactions.append(transaction)
    }
}

@MainActor
@Suite struct WindowSceneAuthorTopologyTests {
    private func makeAuthor() -> (WindowSceneAuthor, SinkRegistry) {
        let registry = SinkRegistry()
        let author = WindowSceneAuthor(commitSinkFactory: { registry.make() })
        return (author, registry)
    }

    @Test func repeatedProductionHostingDoesNotCreateCycle() throws {
        let resourceHost = SwiftResourceHost()
        let store = RetainedTreeStore(resourceHost: resourceHost)
        let runtimeHost = LayerRuntimeHost.inMemory()
        let author = WindowSceneAuthor(commitSinkFactory: {
            RenderCommitSink(
                store: store,
                resourceHost: resourceHost,
                runtimeHost: runtimeHost)
        })
        for surfaceID in [41, 43, 45] as [UInt64] {
            _ = try author.surfaceAttached(
                surfaceID: surfaceID,
                frame: GeometryRect(x: 0, y: 0, width: 1920, height: 1080))
            try author.setWindowOrder([41, 43, 45].filter { $0 <= surfaceID })
        }
        #expect(store.tree.layers.count == 19)
        #expect(store.tree.roots(for: NucleusRenderModel.compositorContextId).count == 1)
    }

    @Test func unchangedOrderAndLayoutDoNotGenerateFrameDemandTransactions() throws {
        let (author, registry) = makeAuthor()
        _ = try author.surfaceAttached(
            surfaceID: 50,
            frame: GeometryRect(x: 0, y: 0, width: 800, height: 600))
        try author.setWindowOrder([50])
        try author.applyLayout(
            surfaceID: 50,
            frame: GeometryRect(x: 0, y: 0, width: 800, height: 600),
            baseSize: GeometrySize(width: 800, height: 572),
            backingFrame: GeometryRect(x: 0, y: 0, width: 800, height: 572),
            chromeInsets: WindowEdgeInsets(top: 28))
        let transactionCount = registry.allTransactions.count

        try author.setWindowOrder([50])
        try author.applyLayout(
            surfaceID: 50,
            frame: GeometryRect(x: 0, y: 0, width: 800, height: 600),
            baseSize: GeometrySize(width: 800, height: 572),
            backingFrame: GeometryRect(x: 0, y: 0, width: 800, height: 572),
            chromeInsets: WindowEdgeInsets(top: 28))
        #expect(registry.allTransactions.count == transactionCount)
    }

    @Test func snapshotOverlayReplacementAndWindowOpacityAreRetainedMutations() throws {
        let (author, registry) = makeAuthor()
        try author.surfaceAttached(
            surfaceID: 60,
            frame: GeometryRect(x: 10, y: 20, width: 800, height: 600))
        try author.beginContentCrossfade(
            surfaceID: 60,
            snapshotHandle: 101)

        let replacementMark = registry.allTransactions.count
        try author.beginContentCrossfade(
            surfaceID: 60,
            snapshotHandle: 202)
        let replacementTransactions = Array(
            registry.allTransactions.dropFirst(replacementMark))
        #expect(replacementTransactions.count == 1)
        let replacement = try #require(replacementTransactions.first)
        #expect(replacement.removed.count == 1)
        #expect(replacement.created.count == 1)
        #expect(replacement.created.first?.1.initialContent.kind == .snapshot)
        #expect(replacement.created.first?.1.initialContent.handle == 202)

        let layoutMark = registry.allTransactions.count
        try author.applyLayout(
            surfaceID: 60,
            frame: GeometryRect(x: 10, y: 20, width: 800, height: 600),
            baseSize: GeometrySize(width: 400, height: 300),
            backingFrame: GeometryRect(x: 0, y: 0, width: 400, height: 300),
            windowOpacity: 0.5,
            overlayOpacity: 0.75)
        let opacityUpdates = registry.allTransactions
            .dropFirst(layoutMark)
            .flatMap(\.propertyUpdates)
            .compactMap(\.properties.opacity)
        #expect(opacityUpdates.contains(0.5))
        #expect(opacityUpdates.contains(0.75))

        let removalMark = registry.allTransactions.count
        try author.endContentCrossfade(surfaceID: 60)
        let removals = registry.allTransactions
            .dropFirst(removalMark)
            .flatMap(\.removed)
        #expect(removals.count == 1)
    }

    @Test func rejectedOverlayMutationRestoresRetryableLocalTopology() throws {
        var sinks: [RejectingCommitSink] = []
        let author = WindowSceneAuthor(commitSinkFactory: {
            let sink = RejectingCommitSink()
            sinks.append(sink)
            return sink
        })
        try author.surfaceAttached(
            surfaceID: 61,
            frame: GeometryRect(x: 0, y: 0, width: 800, height: 600))
        let windowSink = try #require(sinks.last)
        try author.beginContentCrossfade(
            surfaceID: 61,
            snapshotHandle: 101)

        windowSink.rejectNext = true
        #expect(throws: HostCallError.self) {
            try author.beginContentCrossfade(
                surfaceID: 61,
                snapshotHandle: 202)
        }
        let replacementMark = windowSink.transactions.count
        try author.beginContentCrossfade(
            surfaceID: 61,
            snapshotHandle: 202)
        let replacement = try #require(
            windowSink.transactions.dropFirst(replacementMark).first)
        #expect(replacement.removed.count == 1)
        #expect(replacement.created.count == 1)
        #expect(replacement.created.first?.1.initialContent.handle == 202)

        windowSink.rejectNext = true
        #expect(throws: HostCallError.self) {
            try author.endContentCrossfade(surfaceID: 61)
        }
        let removalMark = windowSink.transactions.count
        try author.endContentCrossfade(surfaceID: 61)
        let removal = try #require(
            windowSink.transactions.dropFirst(removalMark).first)
        #expect(removal.removed.count == 1)
    }

    @Test func rejectedSceneRemovalRetriesTheOriginalTopologyRemoval() throws {
        var sinks: [RejectingCommitSink] = []
        let author = WindowSceneAuthor(commitSinkFactory: {
            let sink = RejectingCommitSink()
            sinks.append(sink)
            return sink
        })
        try author.surfaceAttached(
            surfaceID: 62,
            frame: GeometryRect(x: 0, y: 0, width: 800, height: 600))
        let windowSink = try #require(sinks.last)
        try author.beginContentCrossfade(
            surfaceID: 62,
            snapshotHandle: 303)

        windowSink.rejectNext = true
        #expect(throws: LayerError.self) {
            try author.surfaceDestroyed(surfaceID: 62)
        }
        let retryMark = windowSink.transactions.count
        try author.surfaceDestroyed(surfaceID: 62)
        let retry = try #require(
            windowSink.transactions.dropFirst(retryMark).first)
        #expect(retry.removed.count >= 3)
        #expect(retry.detached.count == 1)

        // Fully idempotent after the accepted retry.
        let acceptedCount = windowSink.transactions.count
        try author.surfaceDestroyed(surfaceID: 62)
        #expect(windowSink.transactions.count == acceptedCount)
    }

    @Test func attachBuildsRootHostingAndWindowScene() throws {
        let (author, registry) = makeAuthor()
        let backing = try author.surfaceAttached(
            surfaceID: 1,
            frame: GeometryRect(x: 0, y: 0, width: 800, height: 600)
        )
        #expect(backing != 0)

        // Compositor root context: the root container plus, per window, a host
        // layer and its z-orderable container.
        let rootCreated = registry.created(context: .compositor)
        let rootContainers = rootCreated.filter { $0.1.kind == .container }
        let rootHosts = rootCreated.filter { $0.1.kind == .host }
        #expect(rootContainers.count == 2) // compositor-root container + per-window container
        #expect(rootHosts.count == 1)

        // The window owns its own context; the host layer points back at it.
        let windowContextID = try #require(
            registry.allTransactions.map(\.contextID).first { $0 != .compositor }
        )
        #expect(rootHosts.first?.1.targetContextID == windowContextID)

        // Window scene: root → content → backing, plus a popup root = 4 layers,
        // carrying the window roles.
        let windowCreated = registry.created(context: windowContextID)
        #expect(windowCreated.count == 4)
        let roles = Set(windowCreated.map(\.1.role))
        #expect(roles.contains(.windowRoot))
        #expect(roles.contains(.windowContentViewport))

        // Hosting wiring: host nested inside the per-window container, container
        // nested inside the compositor root.
        let rootInserted = registry.allTransactions
            .filter { $0.contextID == .compositor }
            .flatMap(\.inserted)
        let rootContainerID = try #require(rootInserted.first { $0.parent == nil }?.layer)
        let hostID = try #require(rootHosts.first?.0)
        let hostInsert = try #require(rootInserted.first { $0.layer == hostID })
        let windowContainerID = try #require(hostInsert.parent)
        let containerInsert = try #require(rootInserted.first { $0.layer == windowContainerID })
        #expect(containerInsert.parent == rootContainerID)
    }

    @Test func setWindowOrderReindexesContainers() throws {
        let (author, registry) = makeAuthor()
        try author.surfaceAttached(surfaceID: 1, frame: GeometryRect(x: 0, y: 0, width: 100, height: 100))
        try author.surfaceAttached(surfaceID: 2, frame: GeometryRect(x: 0, y: 0, width: 100, height: 100))

        let rootSink = try #require(registry.rootSink)
        let attachInserts = rootSink.transactions.flatMap(\.inserted)
        let rootContainerID = try #require(attachInserts.first { $0.parent == nil }?.layer)
        // Per-window containers attach into the compositor root, in attach order.
        let windowContainers = attachInserts.filter { $0.parent == rootContainerID }.map(\.layer)
        #expect(windowContainers.count == 2)
        let container1 = windowContainers[0] // surface 1 attached first
        let container2 = windowContainers[1]

        // Reorder so surface 2 is back-most (index 0) and surface 1 front (index 1).
        let mark = rootSink.transactions.count
        try author.setWindowOrder([2, 1])
        let reorderInserts = rootSink.transactions[mark...].flatMap(\.inserted)
        let reorderedContainers = reorderInserts.filter { $0.parent == rootContainerID }
        #expect(reorderedContainers.count == 2)
        let byIndex = Dictionary(uniqueKeysWithValues: reorderedContainers.map { ($0.index, $0.layer) })
        #expect(byIndex[0] == container2)
        #expect(byIndex[1] == container1)

        // Reversing the order swaps the indices.
        let mark2 = rootSink.transactions.count
        try author.setWindowOrder([1, 2])
        let reorder2 = rootSink.transactions[mark2...].flatMap(\.inserted)
        let byIndex2 = Dictionary(uniqueKeysWithValues:
            reorder2.filter { $0.parent == rootContainerID }.map { ($0.index, $0.layer) })
        #expect(byIndex2[0] == container1)
        #expect(byIndex2[1] == container2)
    }

    @Test func destroyTearsDownHostingAndScene() throws {
        let (author, registry) = makeAuthor()
        try author.surfaceAttached(surfaceID: 1, frame: GeometryRect(x: 0, y: 0, width: 100, height: 100))

        let rootSink = try #require(registry.rootSink)
        let hostID = try #require(rootSink.transactions.flatMap(\.created).first { $0.1.kind == .host }?.0)
        let containerID = try #require(
            rootSink.transactions.flatMap(\.inserted).first { $0.layer == hostID }?.parent
        )

        // The window's own context is the second sink minted.
        let windowSink = registry.sinks[1]

        let rootMark = rootSink.transactions.count
        try author.surfaceDestroyed(surfaceID: 1)

        // Root context: host + per-window container removed.
        let rootRemoved = rootSink.transactions[rootMark...].flatMap(\.removed)
        #expect(rootRemoved.contains(hostID))
        #expect(rootRemoved.contains(containerID))

        // Window context: root/content/popup removed, the externally-allocated
        // backing detached (not removed — the feeder still owns its content).
        let windowRemoved = windowSink.transactions.flatMap(\.removed)
        let windowDetached = windowSink.transactions.flatMap(\.detached)
        #expect(windowRemoved.count == 3)
        #expect(windowDetached.count == 1)
    }
}
