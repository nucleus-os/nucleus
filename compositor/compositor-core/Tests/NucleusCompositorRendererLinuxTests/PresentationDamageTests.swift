import Testing
@testable import NucleusRenderer
import NucleusRenderModel

// cross-frame cache begin/commit/retire, native-layer + remote-host change
// detection (initial / unchanged / moved / signature / animation), stale
// retirement, sink routing, and the rect/region math. Hardware-independent.
@Suite struct PresentationDamageTests {
    private final class StubProbe: DamageAnimationProbe {
        var animatedLayers: Set<UInt64> = []
        func subtreeHasActiveAnimations(_ layerId: UInt64) -> Bool { animatedLayers.contains(layerId) }
    }

    static func rect(_ x: Int32, _ y: Int32, _ w: UInt32, _ h: UInt32) -> DamageRect {
        DamageRect(x: x, y: y, width: w, height: h)
    }

    static func nativeFact(_ r: DamageRect, sig: UInt64, layer: UInt64 = 1) -> NativeLayerDamageFact {
        NativeLayerDamageFact(outputId: 1, layerId: layer, visibleRect: r,
                              visualSignature: sig)
    }

    @Test func crossFrameCache() {
        let state = FrameDamageCache()
        let key = NativeLayerKey(outputId: 1, layerId: 7)
        state.beginFrame()
        state.nativeLayerPending[key] = NativeLayerSnapshot(visibleRect: Self.rect(0, 0, 10, 10), visualSignature: 1)
        state.commitFrame()
        #expect(state.nativeLayers[key] != nil, "cache-commit")
        state.beginFrame()
        state.nativeLayerRetired.append(key)
        state.commitFrame()
        #expect(state.nativeLayers[key] == nil, "cache-retire")
    }

    @Test func nativeLayerChangeDetection() {
        let probe = StubProbe()
        // Initial → one current rect.
        let state = FrameDamageCache()
        let tracker = DamageTracker()
        var out = DamageAccumulator()
        tracker.beginFrame(state)
        tracker.trackNativeLayerDamage(state, Self.nativeFact(Self.rect(0, 0, 20, 20), sig: 5), DamageSinks(output: out), probe)
        #expect(out.rects.count == 1, "native-initial")
        state.commitFrame()

        // Unchanged → no rects.
        out = DamageAccumulator()
        tracker.beginFrame(state)
        tracker.trackNativeLayerDamage(state, Self.nativeFact(Self.rect(0, 0, 20, 20), sig: 5), DamageSinks(output: out), probe)
        #expect(out.rects.isEmpty, "native-unchanged")
        state.commitFrame()

        // Moved → exact union of previous + current coverage.
        out = DamageAccumulator()
        tracker.beginFrame(state)
        tracker.trackNativeLayerDamage(state, Self.nativeFact(Self.rect(5, 5, 20, 20), sig: 5), DamageSinks(output: out), probe)
        #expect(out.bounds() == Self.rect(0, 0, 25, 25), "native-moved-bounds")
        #expect(out.overlaps(Self.rect(0, 0, 1, 1)), "native-moved-old-origin")
        #expect(out.overlaps(Self.rect(24, 24, 1, 1)), "native-moved-new-edge")
        state.commitFrame()

        // Signature-only change → one current rect.
        out = DamageAccumulator()
        tracker.beginFrame(state)
        tracker.trackNativeLayerDamage(state, Self.nativeFact(Self.rect(5, 5, 20, 20), sig: 9), DamageSinks(output: out), probe)
        #expect(out.rects.count == 1, "native-signature")
        state.commitFrame()

        // Active animation forces a redraw even when nothing else changed.
        probe.animatedLayers = [1]
        out = DamageAccumulator()
        tracker.beginFrame(state)
        tracker.trackNativeLayerDamage(state, Self.nativeFact(Self.rect(5, 5, 20, 20), sig: 9), DamageSinks(output: out), probe)
        #expect(out.rects.count == 1, "native-animation")
        probe.animatedLayers = []
    }

    @Test func remoteHostChangeDetection() {
        let probe = StubProbe()
        let state = FrameDamageCache()
        let tracker = DamageTracker()
        func remoteFact(_ r: DamageRect, sig: UInt64) -> RemoteHostDamageFact {
            RemoteHostDamageFact(outputId: 1, hostLayerId: 3, targetContextId: ContextID(raw: 2),
                                 rootLayerId: 10, contextRevision: 1,
                                 sourceRect: Rect(x: 0, y: 0, w: 100, h: 100),
                                 visibleRect: r, hostSignature: sig)
        }
        var out = DamageAccumulator()
        tracker.beginFrame(state)
        tracker.trackRemoteHostDamage(state, remoteFact(Self.rect(0, 0, 50, 50), sig: 1), DamageSinks(output: out), probe)
        #expect(out.rects.count == 1 && tracker.remoteHostStats.initial == 1, "remote-initial")
        state.commitFrame()

        out = DamageAccumulator()
        tracker.beginFrame(state)
        tracker.trackRemoteHostDamage(state, remoteFact(Self.rect(10, 10, 50, 50), sig: 1), DamageSinks(output: out), probe)
        #expect(out.bounds() == Self.rect(0, 0, 60, 60), "remote-moved-coverage")
        #expect(tracker.remoteHostStats.visibleRectChanged == 1, "remote-moved-stat")
        state.commitFrame()

        out = DamageAccumulator()
        tracker.beginFrame(state)
        tracker.trackRemoteHostDamage(state, remoteFact(Self.rect(10, 10, 50, 50), sig: 1), DamageSinks(output: out), probe)
        #expect(out.rects.isEmpty && tracker.remoteHostStats.unchanged == 1, "remote-unchanged")
    }

    @Test func staleRetirement() {
        let state = FrameDamageCache()
        let tracker = DamageTracker()
        let key = NativeLayerKey(outputId: 1, layerId: 99)
        state.nativeLayers[key] = NativeLayerSnapshot(visibleRect: Self.rect(1, 2, 3, 4), visualSignature: 1)
        let out = DamageAccumulator()
        tracker.beginFrame(state)
        tracker.addStaleNativeLayerDamage(state, 1, out)
        #expect(out.rects.count == 1 && out.rects[0] == Self.rect(1, 2, 3, 4), "stale-rect")
        #expect(state.nativeLayerRetired.contains(key), "stale-retired")
    }

    @Test func sinkRouting() {
        let tracker = DamageTracker()
        tracker.beginFrame(FrameDamageCache())
        let output = DamageAccumulator()
        let source = DamageAccumulator()
        let sinks = DamageSinks(output: output, source: source)
        tracker.addRect(sinks, .window, Self.rect(0, 0, 5, 5))
        #expect(output.rects.count == 1 && source.rects.count == 1, "route-window")
        tracker.addRect(sinks, .nativeLayer, Self.rect(0, 0, 5, 5))
        #expect(output.overlaps(Self.rect(0, 0, 5, 5)), "route-native-output")
        #expect(source.overlaps(Self.rect(0, 0, 5, 5)), "route-native-source-unchanged")
    }

    @Test func rectRegionMath() {
        #expect(rectsEqual(Self.rect(1, 2, 3, 4), Self.rect(1, 2, 3, 4)), "rects-equal")
        #expect(rectArea(Self.rect(0, 0, 6, 7)) == 42, "rect-area")
        #expect(intersectDamageRects(Self.rect(0, 0, 10, 10), Self.rect(5, 5, 10, 10)) == Self.rect(5, 5, 5, 5), "intersect")
        #expect(intersectDamageRects(Self.rect(0, 0, 4, 4), Self.rect(10, 10, 4, 4)) == nil, "intersect-disjoint")
        #expect(clampDamageRectToTarget(Self.rect(-5, -5, 20, 20), 10, 10) == Self.rect(0, 0, 10, 10), "clamp")
        #expect(clampDamageRectToTarget(Self.rect(20, 20, 5, 5), 10, 10) == nil, "clamp-outside")
        #expect(damageBoundsCoverTarget(Self.rect(0, 0, 100, 100), 100, 100), "covers")
        #expect(!damageBoundsCoverTarget(Self.rect(0, 0, 50, 100), 100, 100), "not-covers")
        #expect(abs(damageBoundsFraction(Self.rect(0, 0, 50, 100), 100, 100) - 0.5) < 1e-9, "fraction")
        #expect(planRectFromDamageRect(Self.rect(3, 4, 5, 6)) == PlanRect(x: 3, y: 4, w: 5, h: 6), "plan-rect")
        #expect(planRectsIntersect(PlanRect(x: 0, y: 0, w: 10, h: 10), PlanRect(x: 5, y: 5, w: 10, h: 10)), "plan-intersect")
        #expect(!planRectsIntersect(PlanRect(x: 0, y: 0, w: 4, h: 4), PlanRect(x: 5, y: 5, w: 4, h: 4)), "plan-disjoint")
    }

    @Test func backdropBlurReconcile() {
        let frame = DamageAccumulator()
        frame.addRect(Self.rect(0, 0, 100, 100))
        let blur = [Self.rect(50, 50, 20, 20), Self.rect(500, 500, 20, 20)]
        let redrawn = reconcileBackdropBlurDamage(frame, blur)
        #expect(redrawn == 1, "blur-redrawn-count")
        #expect(frame.bounds() == Self.rect(0, 0, 100, 100), "blur-covered")
    }

    @Test func accumulatorBoundsBox() {
        let acc = DamageAccumulator()
        #expect(acc.bounds() == nil, "bounds-empty")
        acc.addRect(Self.rect(10, 10, 10, 10))
        acc.addRect(Self.rect(50, 40, 10, 20))
        #expect(acc.bounds() == Self.rect(10, 10, 50, 50), "bounds-box")
    }
}
