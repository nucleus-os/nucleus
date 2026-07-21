import Testing
@_spi(NucleusCompositor) @testable import NucleusUI

@MainActor
@Suite(.uiContext) struct ValueAnimatorTests {
    private final class Owner {}

    @Test func samplesAgainstPredictedPresentationTime() {
        let context = UIContext(services: .inMemory())
        let owner = Owner()
        var values: [Double] = []
        var frameRequests = 0
        context.setAnimationFrameRequestHandler {
            frameRequests += 1
        }

        let handle = context.animateValue(
            owner: owner,
            property: AnimationPropertyKey(rawValue: "progress"),
            from: 0,
            to: 10,
            options: ValueAnimationOptions(
                timing: AnimationTiming(duration: 1, curve: .linear)
            )
        ) {
            values.append($0)
        }

        #expect(frameRequests == 1)
        #expect(context.advanceAnimations(
            predictedPresentationNanoseconds: 1_000_000_000
        ))
        #expect(context.advanceAnimations(
            predictedPresentationNanoseconds: 1_500_000_000
        ))
        #expect(values.last == 5)
        #expect(!context.advanceAnimations(
            predictedPresentationNanoseconds: 2_000_000_000
        ))
        #expect(values.last == 10)
        #expect(handle.outcome == .completed)
    }

    @Test func multipleStartsCoalesceOneFrameRequest() {
        let context = UIContext(services: .inMemory())
        let owner = Owner()
        var requests = 0
        context.setAnimationFrameRequestHandler { requests += 1 }

        context.animateValue(
            owner: owner,
            property: AnimationPropertyKey(rawValue: "x"),
            from: 0,
            to: 1,
            update: { _ in }
        )
        context.animateValue(
            owner: owner,
            property: AnimationPropertyKey(rawValue: "y"),
            from: 0,
            to: 1,
            update: { _ in }
        )

        #expect(requests == 1)
    }

    @Test func replacingAndCancellingResolveExactlyOnce() {
        let context = UIContext(services: .inMemory())
        let owner = Owner()
        let key = AnimationPropertyKey(rawValue: "value")
        var firstOutcomes: [AnimationOutcome] = []
        let first = context.animateValue(
            owner: owner,
            property: key,
            from: 0,
            to: 1,
            update: { _ in }
        ).onCompletion { firstOutcomes.append($0) }
        let second = context.animateValue(
            owner: owner,
            property: key,
            from: 1,
            to: 2,
            update: { _ in }
        )

        #expect(first.outcome == .superseded)
        #expect(firstOutcomes == [.superseded])
        second.cancel()
        second.cancel()
        #expect(second.outcome == .cancelled)
    }

    @Test func destroyedOwnerNeverReceivesAnotherSetter() {
        let context = UIContext(services: .inMemory())
        var owner: Owner? = Owner()
        var setterCount = 0
        let handle = context.animateValue(
            owner: owner!,
            property: AnimationPropertyKey(rawValue: "value"),
            from: 0,
            to: 1,
            update: { _ in setterCount += 1 }
        )
        #expect(setterCount == 1)

        owner = nil
        _ = context.advanceAnimations(
            predictedPresentationNanoseconds: 1_000_000_000
        )
        #expect(setterCount == 1)
        #expect(handle.outcome == .cancelled)
    }

    @Test func realElapsedModeIgnoresReducedMotionAndSpeed() {
        let context = UIContext(services: .inMemory())
        context.updateEnvironment(UIEnvironment(reducesMotion: true))
        context.animationSpeed = 20
        let owner = Owner()
        var value = 0.0
        let handle = context.animateValue(
            owner: owner,
            property: AnimationPropertyKey(rawValue: "deadline"),
            from: 0,
            to: 1,
            options: ValueAnimationOptions(
                timing: AnimationTiming(duration: 1, curve: .linear),
                timeMode: .realElapsed
            ),
            update: { value = $0 }
        )

        #expect(handle.outcome == nil)
        _ = context.advanceAnimations(
            predictedPresentationNanoseconds: 10_000_000_000
        )
        _ = context.advanceAnimations(
            predictedPresentationNanoseconds: 10_500_000_000
        )
        #expect(value == 0.5)
    }

    @Test func reducedMotionSkipsMotionScaledValueSynchronously() {
        let context = UIContext(services: .inMemory())
        context.updateEnvironment(UIEnvironment(reducesMotion: true))
        let owner = Owner()
        var values: [Double] = []
        let handle = context.animateValue(
            owner: owner,
            property: AnimationPropertyKey(rawValue: "visual"),
            from: 0,
            to: 1,
            update: { values.append($0) }
        )

        #expect(values == [0, 1])
        #expect(handle.outcome == .skippedReducedMotion)
    }
}
