import NucleusUITestSupport
import Observation
import Testing

@testable import NucleusLayers
@testable import NucleusUI

@MainActor
@Observable
private final class RetainedObservationModel {
    var usesPrimary = true
    var primary = 0
    var secondary = 0
    var alpha = 1.0
}

@MainActor
private final class ObservationUpdateLatch {
    private(set) var firstUpdates = 0
    private(set) var secondUpdates = 0
    private var expectedUpdates: (first: Int, second: Int)?
    private var continuation: CheckedContinuation<Void, Never>?

    func recordFirstUpdate() {
        firstUpdates += 1
        resumeIfExpected()
    }

    func recordSecondUpdate() {
        secondUpdates += 1
        resumeIfExpected()
    }

    func wait(
        forFirst first: Int,
        second: Int,
        performing mutation: @MainActor () -> Void
    ) async {
        precondition(continuation == nil)
        expectedUpdates = (first, second)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            mutation()
            resumeIfExpected()
        }
    }

    private func resumeIfExpected() {
        guard let expectedUpdates,
            firstUpdates == expectedUpdates.first,
            secondUpdates == expectedUpdates.second,
            let continuation
        else { return }
        self.expectedUpdates = nil
        self.continuation = nil
        continuation.resume()
    }
}

@MainActor
@Suite(.uiContext, .serialized)
/// Release lifecycle gate. Live-token and exactly-once teardown counts are
/// structural invariants, not wall-clock thresholds.
struct NucleusFoundationLifecycleStressTests {
    /// Waits until an observation has produced the effect a check is about to
    /// assert.
    ///
    /// The hops between a write and its observed update are not a constant a
    /// test can count: the Sendable callback re-enters the main actor and the
    /// token yields once more to coalesce a turn's writes, and how many turns
    /// that takes depends on what else the cooperative pool is running.
    /// Waiting on the effect returns as soon as it lands and bounds the wait
    /// rather than reading a half-drained boundary.
    private func settleObservationBoundary(
        until isSettled: @MainActor () -> Bool,
        within timeout: Duration = .seconds(5)
    ) async {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !isSettled() {
            guard ContinuousClock().now < deadline else { return }
            await Task.yield()
        }
    }

    /// Yields enough turns for a pending update to arrive, for a check that
    /// asserts none is coming.
    ///
    /// A check like that cannot be waited into correctness: an update that has
    /// not happened yet and one that will never happen look the same, so this
    /// bounds the window instead of proving a negative. It is also why such a
    /// check never fails early, and why only the waits above could flake.
    private func drainPendingObservationUpdates() async {
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
        await settleObservationBoundary(until: { updates == 2 })

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
            view.alphaValue =
                Double(
                    model.usesPrimary ? model.primary : model.secondary
                ) / 100
        }
        #expect(updates == 1)

        model.usesPrimary = false
        await settleObservationBoundary(until: { updates == 2 })
        #expect(updates == 2)

        // Primary is no longer read, so no update is coming and none can be
        // waited for.
        model.primary = 90
        await drainPendingObservationUpdates()
        #expect(updates == 2)

        model.secondary = 40
        await settleObservationBoundary(until: { updates == 3 })
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
        // The token is cancelled, so the queued update must not arrive.
        await drainPendingObservationUpdates()
        #expect(updates == 1)

        model = nil
        child = nil
        token = nil
        await settleObservationBoundary(until: {
            weakModel == nil && weakChild == nil
                && RetainedObservationToken.liveCount == baseline
        })
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
        await settleObservationBoundary(until: { view.alphaValue == 0.25 })
        #expect(view.alphaValue == 0.25)
        #expect(outcomes == [.completed])

        _ = try publisher.publish(roots: [view])
        #expect(outcomes == [.completed, .completed])
        #expect(
            sink.transactions.last?.propertyUpdates.contains {
                $0.properties.opacity == 0.25
                    && $0.properties.actionPolicy == .default
            } == true)

        model.alpha = 0.5
        await settleObservationBoundary(until: { view.alphaValue == 0.5 })
        token.cancel()
        _ = try publisher.publish(roots: [view])
        #expect(outcomes == [.completed, .completed])
    }

    @Test
    func sharedModelKeepsContextMutationAndTeardownIsolated() async {
        let firstContext = UIContext(services: .inMemory(), runtimeHost: .inMemory())
        let secondContext = UIContext(services: .inMemory(), runtimeHost: .inMemory())
        let firstParent = firstContext.construct { View() }
        let firstView = firstContext.construct { View() }
        let secondParent = secondContext.construct { View() }
        let secondView = secondContext.construct { View() }
        firstParent.addSubview(firstView)
        secondParent.addSubview(secondView)
        let model = RetainedObservationModel()
        let updates = ObservationUpdateLatch()

        _ = firstView.observe(model) { view, model in
            updates.recordFirstUpdate()
            view.isHidden = model.primary.isMultiple(of: 2)
        }
        _ = secondView.observe(model) { view, model in
            updates.recordSecondUpdate()
            view.isHidden = model.primary.isMultiple(of: 2)
        }

        await updates.wait(forFirst: 2, second: 2) {
            model.primary = 1
        }
        #expect(updates.firstUpdates == 2)
        #expect(updates.secondUpdates == 2)
        #expect(!firstView.isHidden)
        #expect(!secondView.isHidden)

        firstView.removeFromSuperview()
        await updates.wait(forFirst: 2, second: 3) {
            model.primary = 2
        }

        #expect(updates.firstUpdates == 2)
        #expect(updates.secondUpdates == 3)
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
        await settleObservationBoundary(until: {
            RetainedObservationToken.liveCount == baseline
        })
        #expect(RetainedObservationToken.liveCount == baseline)
        #expect(parent.subviews.isEmpty)
    }
}
