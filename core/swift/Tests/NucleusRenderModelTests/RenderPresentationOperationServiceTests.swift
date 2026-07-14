@testable import NucleusRenderModel
import Testing

@MainActor
@Suite struct RenderPresentationOperationServiceTests {
    @Test func renderPresentationOperationService() {
        let svc = PresentationOperationService()

        // Id allocation is monotonic + non-none.
        let a = svc.allocOperationID()
        let b = svc.allocOperationID()
        #expect(!a.isNone && !b.isNone && a != b, "alloc-distinct")

        // installFromSnapshot binds the transition to its layer + sets node.
        var tree = LayerTree()
        tree.insertLayer(Layer(id: 1, kind: .container))
        var released: [SnapshotHandle] = []
        let ok = svc.installFromSnapshot(
            tree: &tree, layerId: 1, captureHandle: SnapshotHandle(raw: 100),
            captureSize: Bounds(w: 50, h: 60), fromPosition: Point2D(x: 1, y: 2),
            fromSample: ContentSample(), toGeneration: ContentGeneration(raw: 7),
            expectedCommit: ExpectedCommit(configureSerial: 3, slotGeneration: 4),
            expectedToSize: Bounds(w: 50, h: 60), material: .crossfade,
            progressAtRetarget: 0, durationFractionAtRetarget: 1,
            release: { released.append($0) })
        #expect(ok, "install-ok")
        let opId = tree.get(1)!.presentation.transition
        #expect(!opId.isNone && svc.layer(of: opId) == 1, "install-binds-layer")
        let trans = svc.get(opId)
        #expect(trans?.fromTexture == SnapshotHandle(raw: 100), "install-from-texture")
        // logical_size fell back to capture size (fromSample had zero logical).
        #expect(trans?.fromSize == Bounds(w: 50, h: 60), "install-logical-fallback")
        // content_reveal material wired with a pending target + a hold installed.
        #expect(trans?.materials[fieldIndex(.contentReveal)].from == .snapshot(SnapshotHandle(raw: 100)),
              "install-content-material")
        #expect(trans?.contentRevealHeld() == true, "install-content-hold")

        // install with a bad handle releases + fails.
        let bad = svc.installFromSnapshot(
            tree: &tree, layerId: 1, captureHandle: .none, captureSize: Bounds(w: 1, h: 1),
            fromPosition: Point2D(), fromSample: ContentSample(), toGeneration: .none,
            expectedCommit: nil, expectedToSize: Bounds(), material: .crossfade,
            progressAtRetarget: 0, durationFractionAtRetarget: 1, release: { released.append($0) })
        #expect(!bad && released.contains(.none), "install-bad-handle-releases")

        // Pending presentation updates round-trip + take is destructive.
        svc.putPendingPresentationUpdate(9, .clear(nodeId: 9))
        #expect(svc.takePendingPresentationUpdate(9) == .clear(nodeId: 9), "pending-take")
        #expect(svc.takePendingPresentationUpdate(9) == nil, "pending-take-once")

        // Field-hold sweep: a none-fence + future deadline stays pending.
        _ = svc.installFieldHold(opId, field: .opacity,
            hold: FieldHold(fence: .none, deadlineNs: 1_000, sweep: .clampAtZero))
        #expect(!svc.sweepHolds(nowNs: 500), "sweep-pending-no-change")
        #expect(svc.get(opId)?.holds[fieldIndex(.opacity)] != nil, "sweep-pending-kept")
        // Deadline passed → timed out → clamp policy zeroes progress + clears.
        svc.get(opId).map { _ in () }
        var t2 = svc.get(opId)!
        t2.progress[fieldIndex(.opacity)] = 0.7
        // re-store mutated progress via a fresh install of the hold + progress:
        svc.putOperation(opId, layerId: 1, transition: t2)
        #expect(svc.sweepHolds(nowNs: 2_000), "sweep-timeout-changes")
        #expect(svc.get(opId)?.holds[fieldIndex(.opacity)] == nil &&
              svc.get(opId)?.progress[fieldIndex(.opacity)] == 0, "sweep-clamp-clears")

        // A non-none fence fails closed as cancelled (clears the hold).
        _ = svc.installFieldHold(opId, field: .geometry,
            hold: FieldHold(fence: FenceHandle(raw: 5), deadlineNs: 0, sweep: .freezeAtCurrent))
        #expect(svc.sweepHolds(nowNs: 0), "sweep-fence-cancelled-changes")
        #expect(svc.get(opId)?.holds[fieldIndex(.geometry)] == nil, "sweep-fence-cancelled-clears")
        #expect(PresentationOperationService.fenceState(.none) == .signaled &&
              PresentationOperationService.fenceState(FenceHandle(raw: 1)) == .cancelled, "fence-state")

        // Deadline coalescing keeps the minimum. (Clear any pending deadline
        // left by the earlier field-hold installs first.)
        _ = svc.takeDeadline()
        svc.requestDeadline(5_000)
        svc.requestDeadline(3_000)
        svc.requestDeadline(0) // no-op
        #expect(svc.takeDeadline() == 3_000, "deadline-min")
        #expect(svc.takeDeadline() == nil, "deadline-cleared")

        // takeRetargetSnapshotAndRelease hands back the to-side + releases.
        var t3 = PresentationTransition(operationId: a)
        t3.fromTexture = SnapshotHandle(raw: 200)
        t3.toTexture = SnapshotHandle(raw: 201)
        t3.toSize = Bounds(w: 5, h: 6)
        svc.putOperation(a, layerId: 2, transition: t3)
        released.removeAll()
        let retarget = svc.takeRetargetSnapshotAndRelease(a, release: { released.append($0) })
        #expect(retarget?.handle == SnapshotHandle(raw: 201) && retarget?.size == Bounds(w: 5, h: 6),
              "retarget-returns-to")
        // from + to both released (to was nulled before release, so from + to dedup leaves from + the original to).
        #expect(released.contains(SnapshotHandle(raw: 200)), "retarget-releases-from")
        #expect(svc.get(a) == nil, "retarget-removes-op")

        // clearLayerTransition drops the layer's transition.
        #expect(svc.clearLayerTransition(tree: &tree, layerId: 1, release: { _ in }), "clear-had-transition")
        #expect(tree.get(1)?.presentation.transition.isNone == true && svc.get(opId) == nil, "clear-resets")

        // finishContentReveal: held → not done; unheld → done.
        var heldTrans = PresentationTransition(operationId: a)
        heldTrans.holdContentReveal(FieldHold())
        svc.finishContentReveal(&heldTrans, hasActiveFrameDependency: false)
        #expect(!heldTrans.done, "finish-held-not-done")
        var freeTrans = PresentationTransition(operationId: a)
        svc.finishContentReveal(&freeTrans, hasActiveFrameDependency: false)
        #expect(freeTrans.done, "finish-unheld-done")

        // Update-group depth.
        #expect(!svc.applyingUpdateGroup(), "group-initially-off")
        svc.beginApplyingUpdateGroup()
        #expect(svc.applyingUpdateGroup(), "group-on")
        svc.endApplyingUpdateGroup()
        #expect(!svc.applyingUpdateGroup(), "group-off")
    }
}
