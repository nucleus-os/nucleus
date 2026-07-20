import NucleusRenderHost
import NucleusRenderModel
@_spi(NucleusCompositor) @testable import NucleusUI
import NucleusUIEmbedder
@_spi(NucleusCompositor) @testable import NucleusLayers
import Testing

@MainActor
private final class ApplyingCommitSink: CommitSink {
    var resourceHostHandle: UInt64 { 0 }
    private(set) var transactions: [EncodedTransaction] = []
    private(set) var tree = LayerTree()
    var rejectsCommits = false
    private(set) var rejectedCommitCount = 0

    func commit(_ transaction: EncodedTransaction) throws(LayerError) {
        if rejectsCommits {
            rejectedCommitCount += 1
            throw .backendFailure(detail: "injected publication failure")
        }
        let lowered = RenderTransactionLowering.lower(transaction)
        switch TransactionApplier.apply(lowered, to: &tree) {
        case .success:
            transactions.append(transaction)
        case .failure(let error):
            throw .backendFailure(detail: "render-model rejection: \(error)")
        }
    }
}

@MainActor
private final class DamagePaintView: View {
    var color = Palette.standard(for: .light).error

    override func draw(in context: GraphicsContext) {
        context.fillColor = color
        context.fill(bounds)
    }
}

@MainActor
@Suite(.uiContext) struct ViewPublicationAuthorityTests {
    private func makeContext(
        id: UInt32,
        sink: ApplyingCommitSink
    ) throws -> Context {
        try Context(id: NucleusLayers.ContextID(rawValue: id), commitSink: sink)
    }

    private func makePaintedTree() -> (root: View, child: Label) {
        let root = View()
        root.frame = Rect(x: 4, y: 6, width: 200, height: 100)
        root.backgroundColor = Color(0.1, 0.2, 0.3, 1)
        let child = Label("publication")
        child.frame = Rect(x: 12, y: 14, width: 90, height: 24)
        root.addSubview(child)
        return (root, child)
    }

    @Test func firstPublicationAppliesToTheRealRetainedTree() throws {
        installStubHost()
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_101, sink: sink)
        let tree = makePaintedTree()
        let publisher = ViewLayerPublisher(context: context)

        let published = try publisher.publish(roots: [tree.root])

        let transaction = try #require(sink.transactions.first)
        #expect(!transaction.created.isEmpty)
        #expect(transaction.inserted.allSatisfy { insertion in
            transaction.created.contains { $0.0 == insertion.layer } &&
                (
                    insertion.parent == nil ||
                    transaction.created.contains { $0.0 == insertion.parent }
                )
        })
        #expect(transaction.propertyUpdates.allSatisfy { update in
            transaction.created.contains { $0.0 == update.layer }
        })
        #expect(sink.tree.get(published[0].rootLayerID) != nil)
    }

    @Test func hiddenFirstPublicationAndUnhideRestoreSemanticOpacity() throws {
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_111, sink: sink)
        let publisher = ViewLayerPublisher(context: context)
        let view = View()
        view.alphaValue = 0.65
        view.isHidden = true

        let first = try publisher.publish(roots: [view])
        let layerID = first[0].rootLayerID
        #expect(sink.tree.get(layerID)?.model.properties.opacity == 0)

        view.isHidden = false
        _ = try publisher.publish(roots: [view])
        #expect(sink.tree.get(layerID)?.model.properties.opacity == 0.65)
    }

    @Test func semanticMutationDoesNotTouchTheVisualSinkBeforePublication() throws {
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_102, sink: sink)
        let uiContext = UIContext()

        let root = Application.withContexts(
            uiContext: uiContext,
            visualContext: context
        ) {
            let root = View()
            root.frame = Rect(x: 1, y: 2, width: 30, height: 40)
            root.alphaValue = 0.5
            root.isHidden = true
            root.addSubview(View())
            return root
        }

        #expect(root.uiContext === uiContext)
        #expect(sink.transactions.isEmpty)
        #expect(context.layers.isEmpty)
    }

    @Test func reparentingPreservesVisualIdentityAndRegisteredContent() throws {
        installStubHost()
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_103, sink: sink)
        let root = View()
        let left = View()
        let right = View()
        let label = Label("retained")
        root.addSubview(left)
        root.addSubview(right)
        left.addSubview(label)
        let publisher = ViewLayerPublisher(context: context)

        _ = try publisher.publish(roots: [root])
        let originalLayer = try #require(publisher.visualLayer(for: label))
        let originalContent = originalLayer.descriptor.initialContent
        let transactionCount = sink.transactions.count

        right.addSubview(label)
        _ = try publisher.publish(roots: [root])

        let retainedLayer = try #require(publisher.visualLayer(for: label))
        let rightLayer = try #require(publisher.visualLayer(for: right))
        #expect(retainedLayer === originalLayer)
        #expect(retainedLayer.id == originalLayer.id)
        #expect(retainedLayer.descriptor.initialContent == originalContent)
        #expect(sink.transactions.count == transactionCount + 1)
        let reparent = try #require(sink.transactions.last)
        #expect(reparent.inserted.contains {
            $0.layer == retainedLayer.id && $0.parent == rightLayer.id
        })
        #expect(!reparent.propertyUpdates.contains {
            $0.layer == retainedLayer.id && $0.properties.content != nil
        })
    }

    @Test func hideShowRetainsLayerContentAndAnimationState() throws {
        installStubHost()
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_104, sink: sink)
        let label = Label("persistent")
        label.frame = Rect(x: 0, y: 0, width: 100, height: 24)
        label.animate(.opacity, from: 0, to: 1)
        let publisher = ViewLayerPublisher(context: context)

        _ = try publisher.publish(roots: [label])
        let layer = try #require(publisher.visualLayer(for: label))
        let content = layer.descriptor.initialContent

        label.isHidden = true
        _ = try publisher.publish(roots: [label])
        let hideTransaction = try #require(sink.transactions.last)
        #expect(hideTransaction.propertyUpdates.contains {
            $0.layer == layer.id && $0.properties.opacity == 0
        })
        #expect(hideTransaction.removed.isEmpty)
        #expect(hideTransaction.animationsRemoved.isEmpty)

        label.isHidden = false
        _ = try publisher.publish(roots: [label])
        let shownLayer = try #require(publisher.visualLayer(for: label))
        let showTransaction = try #require(sink.transactions.last)
        #expect(shownLayer === layer)
        #expect(shownLayer.descriptor.initialContent == content)
        #expect(showTransaction.propertyUpdates.contains {
            $0.layer == layer.id && $0.properties.opacity == 1
        })
        #expect(showTransaction.removed.isEmpty)
        #expect(showTransaction.animationsRemoved.isEmpty)
    }

    @Test func removingASubtreeRemovesEveryVisualLayerExactlyOnce() throws {
        installStubHost()
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_105, sink: sink)
        let root = View()
        let branch = View()
        let leaf = Label("leaf")
        root.addSubview(branch)
        branch.addSubview(leaf)
        let publisher = ViewLayerPublisher(context: context)

        _ = try publisher.publish(roots: [root])
        let branchID = try #require(publisher.visualLayer(for: branch)?.id)
        let leafID = try #require(publisher.visualLayer(for: leaf)?.id)

        branch.removeFromSuperview()
        _ = try publisher.publish(roots: [root])

        let removal = try #require(sink.transactions.last)
        #expect(removal.removed == [leafID, branchID])
        #expect(Set(removal.removed).count == 2)
        #expect(publisher.visualLayer(for: branch) == nil)
        #expect(publisher.visualLayer(for: leaf) == nil)
        #expect(context.layers[branchID] == nil)
        #expect(context.layers[leafID] == nil)
    }

    @Test func cleanPublicationEmitsNoTransaction() throws {
        installStubHost()
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_106, sink: sink)
        let tree = makePaintedTree()
        let publisher = ViewLayerPublisher(context: context)

        _ = try publisher.publish(roots: [tree.root])
        let transactionCount = sink.transactions.count
        _ = try publisher.publish(roots: [tree.root])

        #expect(sink.transactions.count == transactionCount)
    }

    @Test func deepTreePublicationUsesFlatTraversalAndLocalizedWork() throws {
        installStubHost()
        let context = Application.makeInMemoryVisualContext()
        let publisher = ViewLayerPublisher(context: context)
        var root = View()
        let leaf = root
        let nodeCount = 4_096
        for _ in 1..<nodeCount {
            let parent = View()
            parent.addSubview(root)
            root = parent
        }

        _ = try publisher.publish(roots: [root])
        #expect(publisher.lastMetrics.nodesVisited == UInt64(nodeCount))
        #expect(publisher.lastMetrics.snapshotsAuthored == UInt64(nodeCount))

        _ = try publisher.publish(roots: [root])
        #expect(publisher.lastMetrics.nodesVisited == 1)
        #expect(publisher.lastMetrics.cleanSubtreesSkipped == 1)
        #expect(publisher.lastMetrics.commits == 0)

        leaf.alphaValue = 0.5
        _ = try publisher.publish(roots: [root])
        #expect(publisher.lastMetrics.nodesVisited == UInt64(nodeCount))
        #expect(publisher.lastMetrics.snapshotsAuthored == 1)
        #expect(publisher.lastMetrics.propertyUpdates == 1)
        #expect(publisher.lastMetrics.commits == 1)
    }

    @Test func wideTreeLeafMutationVisitsOnlyRootAndLeaf() throws {
        installStubHost()
        let context = Application.makeInMemoryVisualContext()
        let publisher = ViewLayerPublisher(context: context)
        let root = View()
        var target: View?
        for index in 0..<4_096 {
            let child = View()
            root.addSubview(child)
            if index == 2_048 {
                target = child
            }
        }
        _ = try publisher.publish(roots: [root])

        target?.alphaValue = 0.25
        _ = try publisher.publish(roots: [root])

        #expect(publisher.lastMetrics.nodesVisited == 2)
        #expect(publisher.lastMetrics.snapshotsAuthored == 1)
        #expect(publisher.lastMetrics.propertyUpdates == 1)
        #expect(publisher.lastMetrics.commits == 1)
    }

    @Test func localDisplayInvalidationsReachTheContentUpdate() throws {
        installStubHost()
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_113, sink: sink)
        let view = DamagePaintView()
        view.frame = Rect(x: 0, y: 0, width: 100, height: 80)
        let publisher = ViewLayerPublisher(context: context)
        _ = try publisher.publish(roots: [view])

        view.color = Palette.standard(for: .dark).primary
        view.setNeedsDisplay(Rect(x: 10, y: 12, width: 20, height: 16))
        _ = try publisher.publish(roots: [view])

        let update = try #require(
            sink.transactions.last?.propertyUpdates.first {
                $0.properties.content != nil
            })
        #expect(update.properties.contentDamage == GeometryRect(
            x: 10,
            y: 12,
            width: 20,
            height: 16))
        #expect(publisher.lastMetrics.localizedPaintUpdates == 1)
        #expect(publisher.lastMetrics.damageRegions == 1)
    }

    @Test func rejectedPublicationKeepsTheAcceptedCacheAndModel() throws {
        installStubHost()
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_107, sink: sink)
        let tree = makePaintedTree()
        let publisher = ViewLayerPublisher(context: context)

        _ = try publisher.publish(roots: [tree.root])
        let layer = try #require(publisher.visualLayer(for: tree.root))
        let acceptedFrame = layer.frame
        let acceptedLayerCount = context.layers.count
        let newChild = Label("not accepted")
        tree.root.addSubview(newChild)
        tree.root.frame = Rect(x: 50, y: 60, width: 300, height: 200)

        sink.rejectsCommits = true
        #expect(throws: UIError.self) {
            _ = try publisher.publish(roots: [tree.root])
        }

        #expect(sink.rejectedCommitCount == 1)
        #expect(publisher.visualLayer(for: tree.root) === layer)
        #expect(publisher.visualLayer(for: newChild) == nil)
        #expect(layer.frame == acceptedFrame)
        #expect(context.layers.count == acceptedLayerCount)

        sink.rejectsCommits = false
        _ = try publisher.publish(roots: [tree.root])
        #expect(publisher.visualLayer(for: newChild) != nil)
        #expect(layer.frame == GeometryRect(x: 50, y: 60, width: 300, height: 200))
    }

    @Test func rejectedPublicationFailsScopedCompletion() throws {
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_112, sink: sink)
        let publisher = ViewLayerPublisher(context: context)
        let view = View()
        _ = try publisher.publish(roots: [view])
        var outcomes: [TransactionOutcome] = []
        let handle = try Transaction.run(
            in: view,
            completion: { outcomes.append($0) }
        ) {
            view.alphaValue = 0.5
        }

        sink.rejectsCommits = true
        #expect(throws: UIError.self) {
            _ = try publisher.publish(roots: [view])
        }
        #expect(handle.outcome == .failed)
        #expect(outcomes == [.failed])
        sink.rejectsCommits = false
        try publisher.invalidate()
    }

    @Test func standaloneAndEmbedderPublicationUseTheSameTopology() throws {
        installStubHost()
        let standaloneSink = ApplyingCommitSink()
        let embedderSink = ApplyingCommitSink()
        let standaloneContext = try makeContext(id: 8_108, sink: standaloneSink)
        let embedderContext = try makeContext(id: 8_109, sink: embedderSink)
        let standaloneTree = makePaintedTree()
        let embedderTree = makePaintedTree()
        let standalone = ViewLayerPublisher(context: standaloneContext)

        _ = try standalone.publish(roots: [standaloneTree.root])
        let embedded = EmbeddedViewTreePublisher(visualContext: embedderContext)
        _ = try embedded.publish(rootView: embedderTree.root)

        let standaloneTransaction = try #require(standaloneSink.transactions.first)
        let embedderTransaction = try #require(embedderSink.transactions.first)
        #expect(
            standaloneTransaction.created.map { $0.1.kind } ==
                embedderTransaction.created.map { $0.1.kind }
        )
        #expect(
            normalizedParents(in: standaloneTransaction) ==
                normalizedParents(in: embedderTransaction)
        )
        #expect(
            standaloneTransaction.propertyUpdates.map {
                $0.properties.content?.kind
            } ==
                embedderTransaction.propertyUpdates.map {
                    $0.properties.content?.kind
                }
        )
    }

    @Test func realApplierSceneLifecyclePreservesTopologyAndReleasesEverything()
        throws
    {
        installStubHost()
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_114, sink: sink)
        let publisher = ViewLayerPublisher(context: context)
        let root = View()
        let left = View()
        let right = View()
        let leaf = DamagePaintView()
        leaf.frame = Rect(x: 2, y: 3, width: 40, height: 30)
        root.addSubview(left)
        root.addSubview(right)
        left.addSubview(leaf)

        _ = try publisher.publish(roots: [root])
        let leafLayer = try #require(publisher.visualLayer(for: leaf))
        let leftLayer = try #require(publisher.visualLayer(for: left))
        #expect(sink.tree.get(leafLayer.id.rawValue)?.parent
            == leftLayer.id.rawValue)

        var completion: TransactionOutcome?
        _ = try Transaction.run(
            in: leaf,
            configuration: .animated,
            completion: { completion = $0 }
        ) {
            leaf.frame = Rect(x: 9, y: 10, width: 44, height: 32)
            leaf.alphaValue = 0.75
        }
        _ = try publisher.publish(roots: [root])
        #expect(completion == nil)
        PresentationCompletionCenter.resolve(
            rawToken: sink.transactions.last?.completionToken ?? 0,
            result: .completed)
        #expect(completion == .completed)
        #expect(sink.tree.get(leafLayer.id.rawValue)?.model.properties.opacity
            == 0.75)

        leaf.isHidden = true
        _ = try publisher.publish(roots: [root])
        #expect(sink.tree.get(leafLayer.id.rawValue)?.model.properties.opacity
            == 0)
        leaf.isHidden = false
        right.addSubview(leaf)
        _ = try publisher.publish(roots: [root])
        let rightLayer = try #require(publisher.visualLayer(for: right))
        #expect(publisher.visualLayer(for: leaf) === leafLayer)
        #expect(sink.tree.get(leafLayer.id.rawValue)?.parent
            == rightLayer.id.rawValue)

        try publisher.invalidate()
        #expect(sink.tree.layers.isEmpty)
        #expect(context.layers.isEmpty)
        #expect(publisher.retainedPaintRegistrationCount == 0)
    }

    @Test func randomizedTreeMutationsMatchTheRealRenderTopology() throws {
        installStubHost()
        let sink = ApplyingCommitSink()
        let context = try makeContext(id: 8_115, sink: sink)
        let publisher = ViewLayerPublisher(context: context)
        let root = View()
        var views = [root]
        for _ in 0..<47 {
            views.append(View())
        }
        for index in 1..<views.count {
            views[(index - 1) / 3].addSubview(views[index])
        }
        _ = try publisher.publish(roots: [root])
        var random = DeterministicRandom(seed: 0x4e55_434c_4555_53)

        for step in 0..<240 {
            let view = views[1 + random.index(views.count - 1)]
            switch random.index(5) {
            case 0:
                view.removeFromSuperview()
            case 1:
                let candidates = attachedViews(rootedAt: root).filter {
                    $0 !== view && !isDescendant($0, of: view)
                }
                if !candidates.isEmpty {
                    candidates[random.index(candidates.count)]
                        .addSubview(view)
                }
            case 2:
                view.frame = Rect(
                    x: Double(random.index(80)),
                    y: Double(random.index(80)),
                    width: Double(1 + random.index(120)),
                    height: Double(1 + random.index(120)))
            case 3:
                view.alphaValue = Double(random.index(101)) / 100
            default:
                view.isHidden.toggle()
            }

            _ = try publisher.publish(roots: [root])
            assertPublishedTopology(
                root: root,
                allViews: views,
                publisher: publisher,
                tree: sink.tree,
                step: step)
        }
        try publisher.invalidate()
    }

    private func assertPublishedTopology(
        root: View,
        allViews: [View],
        publisher: ViewLayerPublisher,
        tree: LayerTree,
        step: Int
    ) {
        let attached = attachedViews(rootedAt: root)
        let attachedIDs = Set(attached.map(\.id))
        for view in allViews {
            guard attachedIDs.contains(view.id) else {
                #expect(
                    publisher.visualLayer(for: view) == nil,
                    "detached semantic node retained a visual at step \(step)")
                continue
            }
            guard let layer = publisher.visualLayer(for: view) else {
                Issue.record(
                    "attached semantic node has no visual at step \(step)")
                continue
            }
            let render = tree.get(layer.id.rawValue)
            #expect(render != nil)
            if let parent = view.superview,
               let parentLayer = publisher.visualLayer(for: parent)
            {
                #expect(
                    render?.parent == parentLayer.id.rawValue,
                    "parent mismatch at step \(step)")
            } else {
                #expect(
                    render?.parent == publisher.publishedRootLayer?.id.rawValue,
                    "root mismatch at step \(step)")
            }
            let semanticChildren = view.subviews.compactMap {
                publisher.visualLayer(for: $0)?.id.rawValue
            }
            #expect(
                render?.children == semanticChildren,
                "sibling order mismatch at step \(step)")
        }
    }

    private func attachedViews(rootedAt root: View) -> [View] {
        var result: [View] = []
        var pending = [root]
        while let view = pending.popLast() {
            result.append(view)
            pending.append(contentsOf: view.subviews.reversed())
        }
        return result
    }

    private func isDescendant(_ candidate: View, of ancestor: View) -> Bool {
        var current: View? = candidate
        while let view = current {
            if view === ancestor { return true }
            current = view.superview
        }
        return false
    }

    private func normalizedParents(
        in transaction: EncodedTransaction
    ) -> [Int?] {
        let indices = Dictionary(uniqueKeysWithValues:
            transaction.created.enumerated().map { ($0.element.0, $0.offset) })
        return transaction.inserted.map { insertion in
            insertion.parent.flatMap { indices[$0] }
        }
    }
}

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func index(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }
}
