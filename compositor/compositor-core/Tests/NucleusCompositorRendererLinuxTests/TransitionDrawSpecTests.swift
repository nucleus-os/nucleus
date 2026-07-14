import Testing
@testable import NucleusRenderer
import NucleusRenderModel

// Converted from TransitionDrawSpecFixture (Phase 9.3): the transition draw
// resolution — texture aliasing, sample oversample factors, the from/to
// texture+sample resolution across held / next-texture / content-sourced
// branches, and the visual footprint geometry. Hardware-independent (a fake
// resolver stands in for the renderer's GPU textures).
@Suite struct TransitionDrawSpecTests {
    private final class FakeTexture: TransitionTexture {
        let width: UInt32
        let height: UInt32
        let imageId: UInt64
        init(_ w: UInt32, _ h: UInt32, image: UInt64) { width = w; height = h; imageId = image }
    }

    private struct FakeResolver: TransitionTextureResolver {
        var snapshots: [UInt64: FakeTexture] = [:]
        var surfaces: [UInt32: FakeTexture] = [:]
        func resolveSnapshotTexture(_ handle: SnapshotHandle) -> TransitionTexture? {
            handle.isNone ? nil : snapshots[handle.raw]
        }
        func lookupIOSurfaceTexture(_ id: IOSurfaceID) -> TransitionTexture? { surfaces[id.raw] }
    }

    static func approxD(_ a: Double, _ b: Double, _ eps: Double = 1e-4) -> Bool { abs(a - b) <= eps }

    static func baseTransition() -> PresentationTransition {
        var trans = PresentationTransition(operationId: OperationID(raw: 1))
        trans.fromTexture = SnapshotHandle(raw: 1)
        trans.fromSize = Bounds(w: 200, h: 100)
        trans.fromPosition = Point2D(x: 5, y: 6)
        trans.toPosition = Point2D(x: 50, y: 60)
        return trans
    }

    @Test func texturesAliasing() {
        let prev = FakeTexture(400, 200, image: 100)
        let next = FakeTexture(800, 400, image: 200)
        #expect(texturesAlias(prev, prev), "alias-self")
        let twin = FakeTexture(10, 10, image: 100)
        #expect(texturesAlias(prev, twin), "alias-same-image")
        #expect(!texturesAlias(prev, next), "alias-distinct")
    }

    @Test func nonHeldWithExplicitToTexture() {
        let prev = FakeTexture(400, 200, image: 100)
        let next = FakeTexture(800, 400, image: 200)
        var resolver = FakeResolver()
        resolver.snapshots[1] = prev
        resolver.snapshots[2] = next
        var trans = Self.baseTransition()
        trans.toTexture = SnapshotHandle(raw: 2)
        trans.toSize = Bounds(w: 400, h: 200)
        trans.setContentRevealProgress(0.4)
        let s = resolveTransitionSamples(resolver, liveTargetSampleOverride: nil, content: .none, trans)!
        #expect(s.texturePrev === prev && s.textureNext === next, "next-texture")
        #expect(Self.approxD(s.fromSample.logicalW, 200) && Self.approxD(s.toSample.logicalW, 400), "next-samples")
        #expect(!s.targetAliasesFrom && abs(s.drawProgress - 0.4) < 1e-5, "next-progress")
        #expect(Self.approxD(sampleScaleX(s.fromSample), 2.0), "sample-scale-x")
        #expect(Self.approxD(sampleScaleY(s.fromSample), 2.0), "sample-scale-y")
    }

    @Test func nextFromExternalContent() {
        let prev = FakeTexture(400, 200, image: 100)
        let next = FakeTexture(800, 400, image: 200)
        var resolver = FakeResolver()
        resolver.snapshots[1] = prev
        resolver.surfaces[9] = next
        let s = resolveTransitionSamples(resolver, liveTargetSampleOverride: nil,
                                         content: .external(IOSurfaceID(raw: 9)), Self.baseTransition())!
        #expect(s.textureNext === next, "content-external")
    }

    @Test func nextFromSnapshotContent() {
        let prev = FakeTexture(400, 200, image: 100)
        let next = FakeTexture(800, 400, image: 200)
        var resolver = FakeResolver()
        resolver.snapshots[1] = prev
        resolver.snapshots[5] = next
        let s = resolveTransitionSamples(resolver, liveTargetSampleOverride: nil,
                                         content: .snapshot(SnapshotHandle(raw: 5)), Self.baseTransition())!
        #expect(s.textureNext === next, "content-snapshot")
    }

    @Test func noNextTextureNil() {
        let prev = FakeTexture(400, 200, image: 100)
        var resolver = FakeResolver()
        resolver.snapshots[1] = prev
        #expect(resolveTransitionSamples(resolver, liveTargetSampleOverride: nil, content: .none, Self.baseTransition()) == nil,
                "no-next-nil")
    }

    @Test func missingFromTextureNil() {
        let resolver = FakeResolver()
        #expect(resolveTransitionSamples(resolver, liveTargetSampleOverride: nil, content: .none, Self.baseTransition()) == nil,
                "no-prev-nil")
    }

    @Test func heldContentReveal() {
        let prev = FakeTexture(400, 200, image: 100)
        var resolver = FakeResolver()
        resolver.snapshots[1] = prev
        var trans = Self.baseTransition()
        trans.setContentRevealProgress(0.7)
        trans.holdContentReveal(FieldHold())
        let s = resolveTransitionSamples(resolver, liveTargetSampleOverride: nil, content: .none, trans)!
        #expect(s.textureNext === prev, "held-next-is-prev")
        #expect(s.toSample == s.fromSample, "held-sample-mirrors")
        #expect(s.drawProgress == 0, "held-progress-zero")
    }

    @Test func visualGeometryUsesExpectedToSize() {
        let prev = FakeTexture(400, 200, image: 100)
        var resolver = FakeResolver()
        resolver.snapshots[1] = prev
        var trans = Self.baseTransition()
        trans.expectedToSize = Bounds(w: 500, h: 300)
        trans.holdContentReveal(FieldHold())
        let s = resolveTransitionSamples(resolver, liveTargetSampleOverride: nil, content: .none, trans)!
        let g = transitionVisualGeometry(trans, fromSample: s.fromSample, toSample: s.toSample)
        #expect(g.fromPosition == Point2D(x: 5, y: 6) && g.toPosition == Point2D(x: 50, y: 60), "geo-positions")
        #expect(Self.approxD(g.fromW, 200) && Self.approxD(g.fromH, 100), "geo-from-size")
        #expect(Self.approxD(g.toW, 500) && Self.approxD(g.toH, 300), "geo-expected-footprint")
    }
}
