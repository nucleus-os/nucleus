@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderPresentationStateTests {
    @Test func renderPresentationState() {
        func approx(_ a: Float, _ b: Float, _ eps: Float = 1e-3) -> Bool { abs(a - b) <= eps }

        // evaluate: clamped endpoints, linear identity, symmetric ease midpoint.
        #expect(TimingFunction.linear.evaluate(-1) == 0 && TimingFunction.linear.evaluate(2) == 1,
              "evaluate-clamps")
        #expect(approx(TimingFunction.linear.evaluate(0.5), 0.5), "evaluate-linear-identity")
        #expect(approx(TimingFunction.easeInEaseOut.evaluate(0.5), 0.5, 1e-2), "evaluate-ease-symmetric-mid")
        // ease-out is front-loaded: at t=0.5 it has progressed past 0.5.
        #expect(TimingFunction.easeOut.evaluate(0.5) > 0.5, "evaluate-ease-out-front-loaded")
        // ease-in is back-loaded: at t=0.5 it lags behind 0.5.
        #expect(TimingFunction.easeIn.evaluate(0.5) < 0.5, "evaluate-ease-in-back-loaded")

        // PresentationUpdate equality across set/clear.
        let s1 = PresentationUpdate.set(nodeId: 1, transform: nil, opacity: 0.5,
            clipExpansion: (1, 2, 3, 4), blurOverride: nil, tintOverride: nil,
            scrollPresentationOffset: nil)
        let s1b = PresentationUpdate.set(nodeId: 1, transform: nil, opacity: 0.5,
            clipExpansion: (1, 2, 3, 4), blurOverride: nil, tintOverride: nil,
            scrollPresentationOffset: nil)
        #expect(s1 == s1b, "pres-update-set-equal")
        let s2 = PresentationUpdate.set(nodeId: 1, transform: nil, opacity: 0.6,
            clipExpansion: (1, 2, 3, 4), blurOverride: nil, tintOverride: nil,
            scrollPresentationOffset: nil)
        #expect(s1 != s2, "pres-update-opacity-differs")
        #expect(PresentationUpdate.clear(nodeId: 1) != s1, "pres-update-clear-differs")
        #expect(PresentationUpdate.clear(nodeId: 1) == .clear(nodeId: 1), "pres-update-clear-equal")

    }
}
