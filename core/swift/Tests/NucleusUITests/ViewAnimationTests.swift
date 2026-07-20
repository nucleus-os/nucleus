import Testing
@_spi(NucleusCompositor) @testable import NucleusUI
@_spi(NucleusCompositor) @testable import NucleusLayers

@MainActor
@Suite(.uiContext) struct ViewAnimationTests {
    private func makeContext() throws -> (Context, InMemoryCommitSink) {
        let sink = InMemoryCommitSink()
        let context = try Context(
            contextID: UInt32.random(in: 100...100_000),
            commitSink: sink
        )
        return (context, sink)
    }

    private func animations(
        for view: View,
        in context: Context,
        sink: InMemoryCommitSink
    ) throws -> [(layer: LayerID, animation: Animation)] {
        let publisher = ViewLayerPublisher(context: context)
        _ = try publisher.publish(roots: [view])
        return sink.transactions.flatMap(\.animationsAdded)
    }

    private func withMotion(
        in uiContext: UIContext,
        reduced: Bool = false,
        speed: Double = 1,
        _ body: () throws -> Void
    ) rethrows {
        let oldEnvironment = uiContext.environment
        let oldSpeed = uiContext.animationSpeed
        var environment = oldEnvironment
        environment.reducesMotion = reduced
        uiContext.updateEnvironment(environment)
        uiContext.animationSpeed = speed
        defer {
            uiContext.updateEnvironment(oldEnvironment)
            uiContext.animationSpeed = oldSpeed
        }
        try body()
    }

    @Test func animatingAssignsModelAndEmitsForTheVisualLayer() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            let handle = view.animate(.opacity, from: 0, to: 1)

            #expect(view.alphaValue == 1)
            #expect(!handle.isFinished)
            let added = try animations(for: view, in: context, sink: sink)
            #expect(added.count == 1)
            #expect(added[0].layer.rawValue != view.id.rawValue)
            #expect(added[0].animation.keyPath == .opacity)
            #expect(added[0].animation.duration == 0.20)
            #expect(handle.outcome == .completed)
        }
    }

    @Test func everyScalarPropertyMapsToOneDistinctLayerKeyPath() {
        let properties: [AnimatableProperty] = [
            .opacity, .cornerRadius, .positionX, .positionY,
            .boundsWidth, .boundsHeight, .scrollOffsetX, .scrollOffsetY,
        ]
        let keyPaths = properties.map(\.keyPath)
        #expect(Set(keyPaths).count == properties.count)
        #expect(AnimatableProperty.scrollOffsetY.keyPath == .scrollOffsetY)
        #expect(AnimatableProperty.boundsWidth.keyPath == .boundsW)
    }

    @Test func springCurveReachesTheLayer() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            view.animate(.positionY, from: 0, to: 100, timing: .spring())
            let added = try animations(for: view, in: context, sink: sink)
            #expect(view.frame.origin.y == 100)
            #expect(added.count == 1)
            #expect(added[0].animation.curve.kind == .spring)
        }
    }

    @Test func removingEmitsARemoval() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            view.animate(.opacity, from: 0, to: 1)
            view.removeAnimation(for: .opacity)

            let publisher = ViewLayerPublisher(context: context)
            _ = try publisher.publish(roots: [view])
            let removed = sink.transactions.flatMap(\.animationsRemoved)
            #expect(removed.count == 1)
            #expect(removed[0].keyPath == .opacity)
        }
    }

    @Test func reducedMotionSkipsPresentationAndCompletesSynchronously() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            try withMotion(in: view.uiContext, reduced: true) {
                let handle = view.animate(.opacity, from: 0, to: 0.7)
                #expect(handle.outcome == .skippedReducedMotion)
                #expect(view.alphaValue == 0.7)
                let added = try animations(for: view, in: context, sink: sink)
                #expect(added.isEmpty)
            }
        }
    }

    @Test func sceneSpeedScalesEveryDuration() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            try withMotion(in: view.uiContext, speed: 2) {
                view.animate(.opacity, from: 0, to: 1, timing: .standard)
                let added = try animations(for: view, in: context, sink: sink)
                #expect(added[0].animation.duration == 0.10)
            }
        }
    }

    @Test func invalidSceneSpeedCanonicalizesToOne() {
        let context = UIContext()
        context.animationSpeed = 0
        #expect(context.animationSpeed == 1)
        context.animationSpeed = -3
        #expect(context.animationSpeed == 1)
        context.animationSpeed = .infinity
        #expect(context.animationSpeed == 1)
    }

    @Test func fadingInUnhidesAndUsesExplicitTarget() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            view.isHidden = true
            view.fadeIn(to: 0.6)

            #expect(!view.isHidden)
            #expect(view.alphaValue == 0.6)
            let added = try animations(for: view, in: context, sink: sink)
            #expect(added.contains { $0.animation.keyPath == .opacity })
        }
    }

    @Test func fadingInWithReducedMotionJustShows() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            try withMotion(in: view.uiContext, reduced: true) {
                view.isHidden = true
                let handle = view.fadeIn()

                #expect(!view.isHidden)
                #expect(view.alphaValue == 1)
                #expect(handle.outcome == .skippedReducedMotion)
                let added = try animations(for: view, in: context, sink: sink)
                #expect(added.isEmpty)
            }
        }
    }

    @Test func fadeOutThenFadeInRestoresOpacity() {
        let view = View()
        view.alphaValue = 0.42
        _ = view.fadeOut()
        #expect(view.alphaValue == 0)
        _ = view.fadeIn()
        #expect(view.alphaValue == 0.42)
    }

    @Test func transformAnimationUsesTypedEndpoints() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            let target = Transform.translation(x: 30, y: 40)
            view.animateTransform(from: .identity, to: target)

            let added = try animations(for: view, in: context, sink: sink)
            #expect(view.transform == target)
            #expect(added.count == 1)
            #expect(added[0].animation.keyPath == .transform)
            #expect(added[0].animation.toEndpoint.transform.m30 == 30)
            #expect(added[0].animation.toEndpoint.transform.m31 == 40)
        }
    }

    @Test func cancellationBeforePublicationIsExactlyOnce() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            var outcomes: [AnimationOutcome] = []
            let handle = view.animate(.opacity, from: 1, to: 0)
                .onCompletion { outcomes.append($0) }
            handle.cancel()
            handle.cancel()

            #expect(outcomes == [.cancelled])
            let publisher = ViewLayerPublisher(context: context)
            _ = try publisher.publish(roots: [view])
            #expect(outcomes == [.cancelled])
            #expect(sink.transactions.flatMap(\.animationsAdded).isEmpty)
        }
    }
}
