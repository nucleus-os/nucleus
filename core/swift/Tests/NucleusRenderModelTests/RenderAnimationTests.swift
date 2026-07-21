@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderAnimationTests {
    @Test func renderAnimation() {
        func approx(_ a: Float, _ b: Float, _ eps: Float = 0.01) -> Bool { abs(a - b) <= eps }
        func ns(_ s: Double) -> UInt64 { UInt64(s * 1_000_000_000.0) }

        let ctx = ContextID(raw: 1)

        func seededStore() -> RetainedTreeStore {
            let store = RetainedTreeStore(resourceHost: SwiftResourceHost())
            var t = Transaction(contextId: ctx)
            var root = LayerCreated(nodeId: 1, kind: .container)
            root.bounds = Bounds(w: 200, h: 200)
            t.created.append(root)
            t.inserted.append(LayerInserted(nodeId: 1, parentId: 0, index: 0))
            store.ingest(t)
            store.markPresented()
            return store
        }

        // --- basic linear opacity 0→1 over 1s ---
        do {
            let store = seededStore()
            store.addAnimation(layerId: 1, AnimationRecord(
                id: AnimationID(raw: 1), layerId: 1,
                animation: .basic(BasicAnimation(
                    keyPath: .opacity, fromValue: 0, toValue: 1, duration: 1.0, timingFunction: .linear))))
            // Seeded to the start value.
            #expect(approx(store.snapshot().get(1)?.presentation.override_?.opacity ?? -1, 0), "opacity-seed")
            #expect(store.hasActiveAnimations, "opacity-active-before")

            let active = store.tick(presentTimeNs: ns(0.5))
            #expect(active, "opacity-tick-active")
            #expect(approx(store.snapshot().get(1)?.effectiveOpacity() ?? -1, 0.5), "opacity-mid")
            #expect(store.hasPendingDamage, "opacity-tick-damage")

            let stillActive = store.tick(presentTimeNs: ns(1.0))
            #expect(!stillActive, "opacity-tick-done")
            #expect(!store.hasActiveAnimations, "opacity-inactive-after")
            // Final value committed to the model; override field cleared.
            #expect(approx(store.snapshot().get(1)?.model.properties.opacity ?? -1, 1.0), "opacity-commit")
            #expect(store.snapshot().get(1)?.presentation.override_?.opacity == nil, "opacity-override-cleared")
            // A completed stop event fired.
            let events = store.drainAnimationEvents()
            let sawStop = events.contains {
                if case .stopped(_, let lid, let kp, _, _, let finished, let reason) = $0 {
                    return lid == 1 && kp == .opacity && finished && reason == .completed
                }
                return false
            }
            #expect(sawStop, "opacity-stop-event")
            #expect(store.drainAnimationEvents().isEmpty, "events-drained")
        }

        // --- damped spring positionX 0→100 settles and commits ---
        do {
            let store = seededStore()
            store.addAnimation(layerId: 1, AnimationRecord(
                id: AnimationID(raw: 2), layerId: 1,
                animation: .spring(SpringAnimation(keyPath: .positionX, fromValue: 0, toValue: 100))))
            var step = 0.016
            while step <= 4.0 {
                store.tick(presentTimeNs: ns(step))
                step += 0.016
            }
            #expect(!store.hasActiveAnimations, "spring-settled")
            #expect(approx(store.snapshot().get(1)?.model.properties.position.x ?? -1, 100, 0.5), "spring-commit")
            #expect(store.snapshot().get(1)?.presentation.override_?.position == nil, "spring-override-cleared")
        }

        // --- compound-frame basic over 1s ---
        do {
            let store = seededStore()
            store.addAnimation(layerId: 1, AnimationRecord(
                id: AnimationID(raw: 3), layerId: 1,
                animation: .basicFrame(BasicFrameAnimation(
                    keyPath: .frame,
                    fromValue: Frame(left: 0, top: 0, right: 100, bottom: 100),
                    toValue: Frame(left: 10, top: 20, right: 110, bottom: 120),
                    duration: 1.0, timingFunction: .linear))))
            store.tick(presentTimeNs: ns(0.5))
            let pos = store.snapshot().get(1)?.effectivePosition() ?? Point2D(x: -1, y: -1)
            let b = store.snapshot().get(1)?.effectiveBounds() ?? Bounds(w: -1, h: -1)
            #expect(approx(pos.x, 5) && approx(pos.y, 10), "frame-mid-position")
            #expect(approx(b.w, 100) && approx(b.h, 100), "frame-mid-bounds")
            store.tick(presentTimeNs: ns(1.0))
            let mp = store.snapshot().get(1)?.model.properties
            #expect(approx(mp?.position.x ?? -1, 10) && approx(mp?.position.y ?? -1, 20), "frame-commit-position")
            #expect(approx(mp?.bounds.w ?? -1, 100) && approx(mp?.bounds.h ?? -1, 120 - 20), "frame-commit-bounds")
            #expect(store.snapshot().get(1)?.presentation.override_ == nil, "frame-override-collapsed")
        }

        // --- transform-component animation rebuilds + clears the matrix ---
        do {
            let store = seededStore()
            store.addAnimation(layerId: 1, AnimationRecord(
                id: AnimationID(raw: 4), layerId: 1,
                animation: .basic(BasicAnimation(
                    keyPath: .transformScaleX, fromValue: 1, toValue: 2, duration: 1.0, timingFunction: .linear))))
            #expect(store.snapshot().get(1)?.presentation.override_?.transform != nil, "transform-seeded")
            store.tick(presentTimeNs: ns(0.5))
            // Halfway: scaleX ~1.5 → matrix m[0] ~1.5 (column-major sx at index 0).
            let m = store.snapshot().get(1)?.presentation.override_?.transform?.m
            #expect(m != nil && approx(m![0], 1.5), "transform-mid-scale")
            store.tick(presentTimeNs: ns(1.0))
            #expect(!store.hasActiveAnimations, "transform-done")
            // Transform components never commit to the model; on completion the
            // override transform collapses away.
            #expect(store.snapshot().get(1)?.presentation.override_?.transform == nil, "transform-cleared")
        }

        // --- velocity-preserving retarget keeps one slot ---
        do {
            let store = seededStore()
            store.addAnimation(layerId: 1, AnimationRecord(
                id: AnimationID(raw: 5), layerId: 1,
                animation: .spring(SpringAnimation(keyPath: .positionX, fromValue: 0, toValue: 100))))
            store.tick(presentTimeNs: ns(0.1))
            _ = store.drainAnimationEvents()
            // Retarget the same slot mid-flight.
            store.addAnimation(layerId: 1, AnimationRecord(
                id: AnimationID(raw: 6), layerId: 1,
                animation: .spring(SpringAnimation(keyPath: .positionX, fromValue: 0, toValue: 50))))
            #expect(store.snapshot().get(1)?.animations.count == 1, "retarget-single-slot")
            let events = store.drainAnimationEvents()
            let sawReplace = events.contains {
                if case .stopped(_, _, _, _, _, _, let reason) = $0 { return reason == .replaced }
                return false
            }
            #expect(sawReplace, "retarget-replaced-event")
        }

        // --- implicit-action table populate + clear ---
        do {
            var table = ImplicitActionTable()
            #expect(table.frameFor(.windowRoot) == nil, "implicit-empty")
            table.replace([
                ImplicitActionRow(role: .windowRoot, keyPath: .frame, kind: .spring,
                                  mass: 2, stiffness: 333, damping: 44),
                ImplicitActionRow(role: .notification, keyPath: .opacity, kind: .scalar,
                                  duration: 0.75, c1x: 0.1, c2x: 0.9, c2y: 1),
            ])
            #expect(approx(table.frameFor(.windowRoot)?.stiffness ?? -1, 333), "implicit-frame")
            #expect((table.opacityFor(.notification)?.duration ?? -1) == 0.75, "implicit-opacity")
            #expect(table.frameFor(.generic) == nil, "implicit-generic-empty")
            table.replace([])
            #expect(table.frameFor(.windowRoot) == nil, "implicit-cleared")
        }
    }
}
