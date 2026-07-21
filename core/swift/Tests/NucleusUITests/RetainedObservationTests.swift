import Observation
@_spi(NucleusCompositor) @testable import NucleusLayers
@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Observable
private final class RetainedObservationModel {
    var usesPrimary = true
    var primary = 0
    var secondary = 0
    var alpha = 1.0
}

@MainActor
@Suite(.uiContext, .serialized)
/// Release lifecycle gate. Live-token and exactly-once teardown counts are
/// structural invariants, not wall-clock thresholds.
struct NucleusFoundationLifecycleStressTests {
    private func settleObservationBoundary() async {
        // Observation's Sendable callback first re-enters the main actor; the
        // token then yields once to coalesce all writes from the current turn.
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    @Test
    func writesCoalesceAndPublishOneRetainedMutation() async throws {
        let sink = InMemoryCommitSink()
        let visualContext = try Context(
            contextID: 9_001,
            commitSink: sink)
        let publisher = ViewLayerPublisher(context: visualContext)
        let model = RetainedObservationModel()
        let view = View()
        var updates = 0

        _ = view.observe(model) { view, model in
            updates += 1
            view.frame = Rect(
                x: Double(model.primary),
                y: 0,
                width: 10,
                height: 10)
        }
        _ = try publisher.publish(roots: [view])
        let baselineTransactionCount = sink.transactions.count

        model.primary = 1
        model.primary = 2
        model.primary = 3
        await settleObservationBoundary()

        #expect(updates == 2)
        #expect(view.frame.origin.x == 3)
        _ = try publisher.publish(roots: [view])
        #expect(sink.transactions.count == baselineTransactionCount + 1)
        #expect(sink.transactions.last?.propertyUpdates.count == 1)
    }

    @Test
    func dependencyTrackingDropsValuesNoLongerRead() async {
        let model = RetainedObservationModel()
        let view = View()
        var updates = 0

        _ = view.observe(model) { view, model in
            updates += 1
            view.alphaValue = Double(
                model.usesPrimary ? model.primary : model.secondary
            ) / 100
        }
        #expect(updates == 1)

        model.usesPrimary = false
        await settleObservationBoundary()
        #expect(updates == 2)

        model.primary = 90
        await settleObservationBoundary()
        #expect(updates == 2)

        model.secondary = 40
        await settleObservationBoundary()
        #expect(updates == 3)
        #expect(view.alphaValue == 0.4)
    }

    @Test
    func hierarchyRemovalCancelsQueuedUpdateAndReleasesCaptures()
        async
    {
        let baseline = RetainedObservationToken.liveCount
        let parent = View()
        var child: View? = View()
        var model: RetainedObservationModel? = RetainedObservationModel()
        weak let weakModel = model
        weak let weakChild = child
        var updates = 0

        parent.addSubview(child!)
        var token: RetainedObservationToken? = child!.observe(
            model!,
            capturePolicy: .strong
        ) { view, model in
            updates += 1
            view.isHidden = model.primary != 0
        }
        #expect(RetainedObservationToken.liveCount == baseline + 1)

        model!.primary = 1
        child!.removeFromSuperview()
        #expect(token?.isCancelled == true)
        await settleObservationBoundary()
        #expect(updates == 1)

        model = nil
        child = nil
        token = nil
        await settleObservationBoundary()
        #expect(weakModel == nil)
        #expect(weakChild == nil)
        #expect(RetainedObservationToken.liveCount == baseline)
    }

    @Test
    func windowRemovalAndSceneDisconnectCancelOwnedObservations() throws {
        let model = RetainedObservationModel()
        let controller = ViewController(view: View())
        let window = Window()
        window.setContentViewController(controller)
        let scene = WindowScene(inMemoryWindows: [window])

        let viewToken = controller.view.observe(model) { _, _ in }
        let controllerToken = controller.observe(model) { _, _ in }
        #expect(!viewToken.isCancelled)
        #expect(!controllerToken.isCancelled)

        #expect(scene.removeWindow(window))

        #expect(viewToken.isCancelled)
        #expect(controllerToken.isCancelled)

        let disconnectView = View()
        let disconnectWindow = Window()
        disconnectWindow.setContentView(disconnectView)
        scene.addWindow(disconnectWindow)
        let disconnectToken = disconnectView.observe(model) { _, _ in }
        #expect(!disconnectToken.isCancelled)

        try scene.disconnect()

        #expect(disconnectToken.isCancelled)
    }

    @Test
    func animatedUpdateIsEagerButCompletionWaitsForAcceptance()
        async throws
    {
        let sink = InMemoryCommitSink()
        let visualContext = try Context(
            contextID: 9_002,
            commitSink: sink)
        let publisher = ViewLayerPublisher(context: visualContext)
        let model = RetainedObservationModel()
        let view = View()
        var outcomes: [TransactionOutcome] = []

        let token = view.observe(
            model,
            configuration: .animated,
            update: { view, model in
                view.alphaValue = model.alpha
            },
            completion: { _, outcome in
                outcomes.append(outcome)
            })
        _ = try publisher.publish(roots: [view])
        #expect(outcomes == [.completed])

        model.alpha = 0.25
        await settleObservationBoundary()
        #expect(view.alphaValue == 0.25)
        #expect(outcomes == [.completed])

        _ = try publisher.publish(roots: [view])
        #expect(outcomes == [.completed, .completed])
        #expect(sink.transactions.last?.propertyUpdates.contains {
            $0.properties.opacity == 0.25
                && $0.properties.actionPolicy == .default
        } == true)

        model.alpha = 0.5
        await settleObservationBoundary()
        token.cancel()
        _ = try publisher.publish(roots: [view])
        #expect(outcomes == [.completed, .completed])
    }

    @Test
    func sharedModelKeepsContextMutationAndTeardownIsolated() async {
        let firstContext = UIContext(services: .inMemory())
        let secondContext = UIContext(services: .inMemory())
        let firstParent = firstContext.construct { View() }
        let firstView = firstContext.construct { View() }
        let secondParent = secondContext.construct { View() }
        let secondView = secondContext.construct { View() }
        firstParent.addSubview(firstView)
        secondParent.addSubview(secondView)
        let model = RetainedObservationModel()
        var firstUpdates = 0
        var secondUpdates = 0

        _ = firstView.observe(model) { view, model in
            firstUpdates += 1
            view.isHidden = model.primary.isMultiple(of: 2)
        }
        _ = secondView.observe(model) { view, model in
            secondUpdates += 1
            view.isHidden = model.primary.isMultiple(of: 2)
        }

        model.primary = 1
        await settleObservationBoundary()
        #expect(firstUpdates == 2)
        #expect(secondUpdates == 2)
        #expect(!firstView.isHidden)
        #expect(!secondView.isHidden)

        firstView.removeFromSuperview()
        model.primary = 2
        await settleObservationBoundary()

        #expect(firstUpdates == 2)
        #expect(secondUpdates == 3)
        #expect(!firstView.isHidden)
        #expect(secondView.isHidden)
        #expect(firstView.uiContext === firstContext)
        #expect(secondView.uiContext === secondContext)
    }

    @Test
    func repeatedCreationAndCancellationReturnsTokensToBaseline() async {
        let baseline = RetainedObservationToken.liveCount
        let parent = View()
        let model = RetainedObservationModel()

        for _ in 0..<128 {
            var view: View? = View()
            parent.addSubview(view!)
            var token: RetainedObservationToken? = view!.observe(model) {
                view, model in
                view.isHidden = model.primary != 0
            }
            view!.removeFromSuperview()
            #expect(token?.isCancelled == true)
            token = nil
            view = nil
        }

        // Fire the model once so Observation also drains any one-shot,
        // weak-token callbacks registered before cancellation.
        model.primary = 1
        await settleObservationBoundary()
        #expect(RetainedObservationToken.liveCount == baseline)
        #expect(parent.subviews.isEmpty)
    }
}
