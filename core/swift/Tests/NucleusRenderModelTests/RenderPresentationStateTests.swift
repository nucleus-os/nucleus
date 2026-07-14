@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderPresentationStateTests {
    @Test func renderPresentationState() {
        func approx(_ a: Float, _ b: Float, _ eps: Float = 1e-3) -> Bool { abs(a - b) <= eps }

        // timingFunction maps each template to its curve.
        #expect(timingFunction(.default) == .easeInEaseOut, "timing-default")
        #expect(timingFunction(.linear) == .linear, "timing-linear")
        #expect(timingFunction(.easeIn) == .easeIn, "timing-ease-in")
        #expect(timingFunction(.easeOut) == .easeOut, "timing-ease-out")
        #expect(timingFunction(.easeInEaseOut) == .easeInEaseOut, "timing-ease-in-out")

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

        // Material-rect extraction.
        let rect = Rect(x: 1, y: 2, w: 30, h: 40)
        #expect(rectFromMaterialSource(.value(.rect(rect))) == rect, "rect-from-source-value")
        #expect(rectFromMaterialSource(.snapshot(SnapshotHandle(raw: 1))) == nil, "rect-from-source-non-rect")
        #expect(rectFromMaterialSource(.value(.scalar(3))) == nil, "rect-from-source-scalar")
        #expect(rectFromMaterialTarget(.value(.rect(rect))) == rect, "rect-from-target-value")
        #expect(rectFromMaterialTarget(.pending(ExpectedCommit(configureSerial: 1, slotGeneration: 1))) == nil,
              "rect-from-target-pending")

        // geometryMaterialRects pulls the geometry field's from/to rects.
        var trans = PresentationTransition(operationId: OperationID(raw: 1))
        let fromRect = Rect(x: 0, y: 0, w: 10, h: 10)
        let toRect = Rect(x: 5, y: 5, w: 20, h: 20)
        var gm = FieldMaterial()
        gm.from = .value(.rect(fromRect))
        gm.to = .value(.rect(toRect))
        trans.materials[fieldIndex(.geometry)] = gm
        #expect(geometryMaterialRects(trans) == GeometryRects(from: fromRect, to: toRect),
              "geometry-material-rects")
        // Missing a concrete to rect → nil.
        var trans2 = PresentationTransition(operationId: OperationID(raw: 2))
        var gm2 = FieldMaterial()
        gm2.from = .value(.rect(fromRect))
        gm2.to = .none
        trans2.materials[fieldIndex(.geometry)] = gm2
        #expect(geometryMaterialRects(trans2) == nil, "geometry-material-rects-incomplete")

        // Content-reveal default action: role-independent 0.22s ease-out.
        let cra = defaultActionForContentReveal(.generic)
        #expect(cra.duration == 0.22 && cra.timingFunction == .easeOut, "content-reveal-default")
        #expect(defaultActionForContentReveal(.windowRoot) == cra, "content-reveal-role-independent")
    }
}
