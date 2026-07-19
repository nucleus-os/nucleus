import Testing
@_spi(NucleusCompositor) @testable import NucleusUI
@_spi(NucleusCompositor) @testable import NucleusLayers

/// View-tier animation. The layers tier already had bezier and spring curves;
/// this is the seam that lets a product view reach them.
@MainActor
@Suite struct ViewAnimationTests {
    /// Each test runs in its own context so the committed transaction contains
    /// only its own work.
    private func makeContext() throws -> (Context, InMemoryCommitSink) {
        let sink = InMemoryCommitSink()
        let context = try Context(contextID: UInt32.random(in: 100...100_000), commitSink: sink)
        return (context, sink)
    }

    private func animations(
        _ context: Context, _ sink: InMemoryCommitSink
    ) throws -> [(layer: LayerID, animation: Animation)] {
        try LayerTransaction.flushImplicit(in: context)
        return sink.transactions.flatMap(\.animationsAdded)
    }

    private func withMotion(
        enabled: Bool = true, speed: Double = 1, _ body: () throws -> Void
    ) rethrows {
        let wasEnabled = Motion.isEnabled
        let wasSpeed = Motion.speed
        Motion.isEnabled = enabled
        Motion.speed = speed
        defer {
            Motion.isEnabled = wasEnabled
            Motion.speed = wasSpeed
        }
        try body()
    }

    // MARK: - Reaching the layer tier

    @Test func animatingEmitsAnAnimationForTheViewsLayer() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            #expect(view.animate(.opacity, from: 0, to: 1))

            let added = try animations(context, sink)
            #expect(added.count == 1)
            #expect(added[0].layer == view.backingLayer.id)
            #expect(added[0].animation.keyPath == .opacity)
            #expect(added[0].animation.duration == 0.20)
        }
    }

    /// Every animatable property maps onto a distinct layer keypath. A wrong
    /// mapping would animate the wrong thing silently.
    @Test func everyPropertyMapsToItsOwnKeyPath() {
        let properties: [AnimatableProperty] = [
            .opacity, .cornerRadius, .positionX, .positionY,
            .boundsWidth, .boundsHeight, .scrollOffsetX, .scrollOffsetY,
        ]
        let keyPaths = properties.map(\.keyPath)
        #expect(Set(keyPaths).count == properties.count, "no two share a keypath")
        #expect(AnimatableProperty.scrollOffsetY.keyPath == .scrollOffsetY)
        #expect(AnimatableProperty.boundsWidth.keyPath == .boundsW)
    }

    @Test func theCurveReachesTheLayer() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            view.animate(.positionY, from: 0, to: 100, timing: .spring())

            let added = try animations(context, sink)
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

            try LayerTransaction.flushImplicit(in: context)
            let removed = sink.transactions.flatMap(\.animationsRemoved)
            #expect(removed.count == 1)
            #expect(removed[0].keyPath == .opacity)
        }
    }

    // MARK: - Motion policy

    /// Reduce-motion skips the animation rather than shortening it, so a
    /// property takes its final value at once instead of moving very fast.
    @Test func disablingMotionSkipsTheAnimation() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            try withMotion(enabled: false) {
                let view = View()
                #expect(!view.animate(.opacity, from: 0, to: 1),
                        "reports that nothing was started")
                let added = try animations(context, sink)
                #expect(added.isEmpty)
            }
        }
    }

    @Test func speedScalesEveryDuration() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            try withMotion(speed: 2) {
                let view = View()
                view.animate(.opacity, from: 0, to: 1, timing: .standard)
                let added = try animations(context, sink)
                #expect(added[0].animation.duration == 0.10, "half of 0.20")
            }
        }
    }

    /// A zero or negative speed would divide durations into nonsense, so it is
    /// refused rather than propagated.
    @Test func anInvalidSpeedIsRejected() {
        let previous = Motion.speed
        defer { Motion.speed = previous }

        Motion.speed = 0
        #expect(Motion.speed == 1)
        Motion.speed = -3
        #expect(Motion.speed == 1)
    }

    // MARK: - Fades

    /// A hidden layer does not composite, so unhiding has to come first or the
    /// fade runs invisibly and pops at the end.
    @Test func fadingInUnhidesBeforeAnimating() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            let view = View()
            view.isHidden = true
            view.fadeIn()

            #expect(!view.isHidden)
            let added = try animations(context, sink)
            #expect(added.contains { $0.animation.keyPath == .opacity })
        }
    }

    /// With motion off, a fade-in is just the unhide — the view appears at its
    /// final opacity, which is the correct reduced behaviour.
    @Test func fadingInWithoutMotionJustShows() throws {
        let (context, sink) = try makeContext()
        try Application.withContext(context) {
            try withMotion(enabled: false) {
                let view = View()
                view.isHidden = true
                view.fadeIn()

                #expect(!view.isHidden)
                #expect(view.alphaValue == 1)
                let added = try animations(context, sink)
                #expect(added.isEmpty)
            }
        }
    }

    /// Fading out lands on transparent either way — the animation is how it gets
    /// there, not whether it arrives.
    @Test func fadingOutReachesTransparentWithOrWithoutMotion() throws {
        let (context, _) = try makeContext()
        try Application.withContext(context) {
            let animated = View()
            animated.fadeOut()
            #expect(animated.alphaValue == 0)

            try withMotion(enabled: false) {
                let immediate = View()
                immediate.fadeOut()
                #expect(immediate.alphaValue == 0)
            }
        }
    }
}
