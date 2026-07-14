// Phase 8.11 — Swift presentation-operation + fence ownership service.
//
// Layers store only operation ids; this service owns the mutable operation
// tables, the per-layer pending presentation updates, and the requested
// deadline. Field holds with an unresolved non-none fence fail closed as
// cancelled.
//
// The `snapshot_owner.releaseSnapshot` indirection becomes a `release:` closure
// (the render server wires it to its snapshot service + texture free in 10b);
// tree-mutating installs take `inout LayerTree`. A reference type — shared,
// mutable service state. Nothing imports this yet; the render server driving it
// co-lands with the renderer move (10b).
//
// `FenceState` is defined here as its first Swift consumer.

/// Resolution state of a fence.
public enum FenceState {
    case pending
    case signaled
    case timedOut
    case cancelled
}

/// Owns presentation-transition operations + pending presentation updates.
/// Mirrors `PresentationOperationService`.
public final class PresentationOperationService {
    private var operations: [OperationID: PresentationTransition] = [:]
    private var operationLayers: [OperationID: UInt64] = [:]
    private var pendingPresentation: [UInt64: PresentationUpdate] = [:]
    private var nextOperationId: UInt64 = 1
    private var operationDeadlineNs: UInt64?
    private var applyingUpdateGroupDepth: UInt32 = 0

    public init() {}

    // MARK: Operation ids + lookup

    /// Allocate a fresh operation id (u64 wrap, skip 0). Mirrors
    /// `allocOperationID`.
    public func allocOperationID() -> OperationID {
        let id = nextOperationId
        nextOperationId &+= 1
        if nextOperationId == 0 { nextOperationId = 1 }
        return OperationID(raw: id)
    }

    /// Read an operation by id, or `nil` for `none`/unknown. Mirrors `get`.
    public func get(_ operationId: OperationID) -> PresentationTransition? {
        if operationId.isNone { return nil }
        return operations[operationId]
    }

    /// The layer an operation is bound to. (`operation_layers` lookup.)
    public func layer(of operationId: OperationID) -> UInt64? {
        operationLayers[operationId]
    }

    /// Store an operation + its layer binding. Mirrors `putOperation`.
    public func putOperation(_ operationId: OperationID, layerId: UInt64, transition: PresentationTransition) {
        operations[operationId] = transition
        operationLayers[operationId] = layerId
    }

    @discardableResult
    private func removeOperation(_ operationId: OperationID) -> PresentationTransition? {
        if operationId.isNone { return nil }
        guard let trans = operations.removeValue(forKey: operationId) else { return nil }
        operationLayers[operationId] = nil
        return trans
    }

    private func removeLayerBinding(_ operationId: OperationID) {
        operationLayers[operationId] = nil
    }

    // MARK: Install

    /// Build + install a content-reveal transition from a captured snapshot,
    /// binding it to `layerId`. Returns false (releasing the capture) on a bad
    /// handle/size or a missing layer. Mirrors `installFromSnapshot`.
    @discardableResult
    public func installFromSnapshot(
        tree: inout LayerTree,
        layerId: UInt64,
        captureHandle: SnapshotHandle,
        captureSize: Bounds,
        fromPosition: Point2D,
        fromSample: ContentSample,
        toGeneration: ContentGeneration,
        expectedCommit: ExpectedCommit?,
        expectedToSize: Bounds,
        material: PresentationTransitionMaterial,
        progressAtRetarget: Float,
        durationFractionAtRetarget: Float,
        release: (SnapshotHandle) -> Void
    ) -> Bool {
        if captureHandle.isNone || captureSize.w <= 0 || captureSize.h <= 0 {
            release(captureHandle)
            return false
        }
        guard tree.get(layerId) != nil else {
            release(captureHandle)
            return false
        }

        let operationId = allocOperationID()
        var fromLogicalSize = fromSample.logicalSize
        if fromLogicalSize.w <= 0 || fromLogicalSize.h <= 0 {
            fromLogicalSize = captureSize
        }
        var trans = PresentationTransition(operationId: operationId, expectedCommit: expectedCommit)
        trans.fromTexture = captureHandle
        trans.fromSize = fromLogicalSize
        trans.fromPosition = fromPosition
        trans.fromSample = fromSample
        trans.toGeneration = toGeneration
        trans.expectedToSize = expectedToSize
        trans.toPosition = fromPosition
        trans.progressAtRetarget = progressAtRetarget
        trans.durationFractionAtRetarget = durationFractionAtRetarget
        trans.material = material
        trans.setContentRevealProgress(progressAtRetarget)
        trans.materials[fieldIndex(.contentReveal)] = FieldMaterial(
            from: .snapshot(captureHandle),
            to: expectedCommit.map { .pending($0) } ?? .none)
        trans.holds[fieldIndex(.contentReveal)] = FieldHold(fence: .none, deadlineNs: 0, sweep: .clampAtZero)

        putOperation(operationId, layerId: layerId, transition: trans)
        tree.layers[layerId]!.presentation.transition = operationId
        return true
    }

    /// Resolve a captured snapshot's from-sample fallbacks against the layer's
    /// bounds, then install. Mirrors `installCaptured`.
    @discardableResult
    public func installCaptured(
        tree: inout LayerTree,
        layerId: UInt64,
        capture: CaptureResult,
        toGeneration: ContentGeneration,
        expectedCommit: ExpectedCommit?,
        fromSampleOpt: ContentSample?,
        expectedToSize: Bounds,
        material: PresentationTransitionMaterial,
        release: (SnapshotHandle) -> Void
    ) -> Bool {
        if capture.handle.isNone || capture.size.w <= 0 || capture.size.h <= 0 {
            release(capture.handle)
            return false
        }
        guard let node = tree.get(layerId) else {
            release(capture.handle)
            return false
        }
        let fallbackFromSize = Bounds(
            w: node.model.properties.bounds.w > 0 ? node.model.properties.bounds.w : capture.size.w,
            h: node.model.properties.bounds.h > 0 ? node.model.properties.bounds.h : capture.size.h)
        var fromSample = fromSampleOpt ?? ContentSample(
            srcOrigin: (0, 0), srcSize: (capture.size.w, capture.size.h), logicalSize: fallbackFromSize)
        if fromSample.srcSize.0 <= 0 || fromSample.srcSize.1 <= 0 {
            fromSample.srcOrigin = (0, 0)
            fromSample.srcSize = (capture.size.w, capture.size.h)
        }
        if fromSample.logicalSize.w <= 0 || fromSample.logicalSize.h <= 0 {
            fromSample.logicalSize = fallbackFromSize
        }

        return installFromSnapshot(
            tree: &tree, layerId: layerId, captureHandle: capture.handle, captureSize: capture.size,
            fromPosition: node.effectivePosition(), fromSample: fromSample, toGeneration: toGeneration,
            expectedCommit: expectedCommit, expectedToSize: expectedToSize, material: material,
            progressAtRetarget: 0, durationFractionAtRetarget: 1, release: release)
    }

    // MARK: Pending presentation updates

    public func takePendingPresentationUpdate(_ layerId: UInt64) -> PresentationUpdate? {
        pendingPresentation.removeValue(forKey: layerId)
    }

    public func putPendingPresentationUpdate(_ layerId: UInt64, _ update: PresentationUpdate) {
        pendingPresentation[layerId] = update
    }

    public func removePendingPresentationUpdate(_ layerId: UInt64) {
        pendingPresentation[layerId] = nil
    }

    // MARK: Field holds + sweep

    /// Install a field hold on an operation, requesting its deadline. A non-none
    /// fence with no deadline is logged-and-kept (the sweep fails it closed).
    /// Mirrors `installFieldHold`.
    @discardableResult
    public func installFieldHold(_ operationId: OperationID, field: TransitionField, hold: FieldHold) -> Bool {
        guard operations[operationId] != nil else { return false }
        operations[operationId]!.holds[fieldIndex(field)] = hold
        requestDeadline(hold.deadlineNs)
        return true
    }

    /// Resolve every operation's holds against `nowNs`: signaled/cancelled holds
    /// clear; timed-out holds apply the sweep policy (clamp/freeze/skip) then
    /// clear. Returns whether anything changed. Mirrors `sweepHolds`.
    @discardableResult
    public func sweepHolds(nowNs: UInt64) -> Bool {
        var changed = false
        for operationId in operations.keys {
            for fieldIdx in 0..<transitionFieldCount {
                guard let hold = operations[operationId]!.holds[fieldIdx] else { continue }
                if hold.fence.isNone && hold.deadlineNs == 0 { continue }
                let state: FenceState
                if !hold.fence.isNone {
                    state = Self.fenceState(hold.fence)
                } else if hold.deadlineNs <= nowNs {
                    state = .timedOut
                } else {
                    state = .pending
                }
                switch state {
                case .pending:
                    break
                case .signaled, .cancelled:
                    operations[operationId]!.holds[fieldIdx] = nil
                    changed = true
                case .timedOut:
                    switch hold.sweep {
                    case .clampAtZero: operations[operationId]!.progress[fieldIdx] = 0
                    case .freezeAtCurrent: break
                    case .skipToOne: operations[operationId]!.progress[fieldIdx] = 1
                    }
                    operations[operationId]!.holds[fieldIdx] = nil
                    changed = true
                }
            }
        }
        return changed
    }

    // MARK: Removal + retarget

    /// Remove an operation and release its transition's textures. Mirrors
    /// `removeAndRelease`.
    @discardableResult
    public func removeAndRelease(_ operationId: OperationID, release: (SnapshotHandle) -> Void) -> Bool {
        guard let trans = removeOperation(operationId) else { return false }
        releaseTransitionResources(trans, release: release)
        return true
    }

    /// Clear the transition bound to `layerId`, releasing its resources. Returns
    /// whether the layer had a transition. Mirrors `clearLayerTransition`.
    @discardableResult
    public func clearLayerTransition(tree: inout LayerTree, layerId: UInt64, release: (SnapshotHandle) -> Void) -> Bool {
        guard let node = tree.get(layerId) else { return false }
        let operationId = node.presentation.transition
        let hadTransition = !operationId.isNone
        _ = removeAndRelease(operationId, release: release)
        tree.layers[layerId]!.presentation.transition = .none
        return hadTransition
    }

    /// Remove an operation, returning its `to` side as a retarget snapshot (if
    /// it had one) and releasing the rest. Mirrors
    /// `takeRetargetSnapshotAndRelease`.
    public func takeRetargetSnapshotAndRelease(_ operationId: OperationID, release: (SnapshotHandle) -> Void) -> RetargetSnapshot? {
        guard var trans = removeOperation(operationId) else {
            removeLayerBinding(operationId)
            return nil
        }
        let result: RetargetSnapshot? = !trans.toTexture.isNone
            ? RetargetSnapshot(handle: trans.toTexture, size: trans.toSize, position: trans.toPosition,
                               sample: trans.toSample, progress: trans.contentRevealProgress())
            : nil
        trans.toTexture = .none
        releaseTransitionResources(trans, release: release)
        return result
    }

    /// Mark a transition done unless its content-reveal is still held. Mirrors
    /// `finishContentReveal`.
    public func finishContentReveal(_ trans: inout PresentationTransition, hasActiveFrameDependency: Bool) {
        if trans.contentRevealHeld() {
            trans.done = false
            return
        }
        _ = hasActiveFrameDependency
        trans.done = true
    }

    // MARK: Update-group depth + deadline

    public func applyingUpdateGroup() -> Bool { applyingUpdateGroupDepth != 0 }

    public func beginApplyingUpdateGroup() {
        assert(applyingUpdateGroupDepth == 0)
        applyingUpdateGroupDepth += 1
    }

    public func endApplyingUpdateGroup() {
        applyingUpdateGroupDepth -= 1
    }

    /// Lower the pending operation deadline toward `deadlineNs` (0 = no-op).
    /// Mirrors `requestDeadline`.
    public func requestDeadline(_ deadlineNs: UInt64) {
        if deadlineNs == 0 { return }
        operationDeadlineNs = operationDeadlineNs.map { min($0, deadlineNs) } ?? deadlineNs
    }

    /// Take + clear the pending deadline. Mirrors `takeDeadline`.
    public func takeDeadline() -> UInt64? {
        let deadline = operationDeadlineNs
        operationDeadlineNs = nil
        return deadline
    }

    /// Dormant fence resolution: `none` reads as signaled, any other handle as
    /// cancelled (fail-closed — the real fence registry lands with the renderer
    /// move). Mirrors the file-local `fenceState`.
    public static func fenceState(_ handle: FenceHandle) -> FenceState {
        handle.isNone ? .signaled : .cancelled
    }
}

/// Release a transition's from/to textures (deduped). Mirrors
/// `releaseTransitionResources`.
private func releaseTransitionResources(_ trans: PresentationTransition, release: (SnapshotHandle) -> Void) {
    release(trans.fromTexture)
    if trans.toTexture != trans.fromTexture { release(trans.toTexture) }
}
