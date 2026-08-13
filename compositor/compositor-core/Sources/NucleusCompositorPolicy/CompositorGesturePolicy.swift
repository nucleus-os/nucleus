package import NucleusCompositorServer
package import NucleusCompositorServerTypes

package enum CompositorOverviewKind: Sendable, Equatable {
    case windows
    case spaces
}

/// The complete render-facing overview contract. `progress` is the visible
/// fraction in the closed range 0...1; interactive states are previews owned by
/// the active gesture and noninteractive states are committed policy.
package struct CompositorOverviewState: Sendable, Equatable {
    package let kind: CompositorOverviewKind
    package let outputID: DisplayID
    package let progress: Double
    package let interactive: Bool
}

@MainActor
package final class CompositorGesturePolicy {
    package typealias OverviewSink =
        @MainActor (_ outputID: DisplayID, _ state: CompositorOverviewState?) -> Void

    private enum SwipeAxis {
        case horizontal
        case vertical
    }

    private enum Interaction {
        case swipe(deltaX: Double, deltaY: Double, axis: SwipeAxis?)
        case pinch(scale: Double)
    }

    private struct ActiveGesture {
        let sequence: NormalizedGestureSequence
        let target: GesturePolicyTarget
        let originalOverview: CompositorOverviewKind?
        var interaction: Interaction
    }

    private static let axisLockDistance = 24.0
    private static let axisDominance = 1.25
    private static let swipeCommitDistance = 120.0
    private static let pinchCommitScaleIn = 0.75
    private static let pinchCommitScaleOut = 1.25

    private let server: NucleusCompositorServer
    private var capturedSequences: Set<NormalizedGestureSequence> = []
    private var activeGesture: ActiveGesture?
    private var overviewByOutput: [DisplayID: CompositorOverviewKind] = [:]

    package var overviewSink: OverviewSink?

    package init(server: NucleusCompositorServer) {
        self.server = server
    }

    package func overview(on outputID: DisplayID) -> CompositorOverviewKind? {
        overviewByOutput[outputID]
    }

    package func dispatch(
        _ event: NormalizedGestureEvent,
        target: GesturePolicyTarget?
    ) -> GesturePolicyOutcome {
        switch event {
        case .began(let sequence, _):
            return begin(sequence, target: target)
        case .swipeUpdated(let sequence, _, let deltaX, let deltaY):
            return updateSwipe(
                sequence, deltaX: deltaX, deltaY: deltaY, target: target)
        case .pinchUpdated(let sequence, _, _, _, let scale, _):
            return updatePinch(sequence, scale: scale, target: target)
        case .ended(let sequence, _, let cancelled):
            return end(sequence, cancelled: cancelled, target: target)
        }
    }

    package func cancelActiveGesture() {
        rollbackActiveGesture()
    }

    package func outputWillRemove(_ outputID: DisplayID) {
        if activeGesture?.target.outputID == outputID {
            activeGesture = nil
        }
        overviewByOutput[outputID] = nil
        overviewSink?(outputID, nil)
    }

    private func begin(
        _ sequence: NormalizedGestureSequence,
        target: GesturePolicyTarget?
    ) -> GesturePolicyOutcome {
        if activeGesture != nil { rollbackActiveGesture() }
        guard isBound(sequence), let target, outputExists(target.outputID) else {
            return .client
        }

        capturedSequences.insert(sequence)
        let interaction: Interaction =
            sequence.kind == .swipe
            ? .swipe(deltaX: 0, deltaY: 0, axis: nil)
            : .pinch(scale: 1)
        activeGesture = ActiveGesture(
            sequence: sequence,
            target: target,
            originalOverview: overviewByOutput[target.outputID],
            interaction: interaction)
        return .compositor(redrawOutputID: nil)
    }

    private func updateSwipe(
        _ sequence: NormalizedGestureSequence,
        deltaX: Double,
        deltaY: Double,
        target: GesturePolicyTarget?
    ) -> GesturePolicyOutcome {
        guard capturedSequences.contains(sequence) else { return .client }
        guard var active = validActiveGesture(sequence: sequence, target: target),
            case .swipe(var totalX, var totalY, var axis) = active.interaction
        else { return .compositor(redrawOutputID: nil) }

        totalX += deltaX
        totalY += deltaY
        if axis == nil { axis = lockedAxis(deltaX: totalX, deltaY: totalY) }
        active.interaction = .swipe(deltaX: totalX, deltaY: totalY, axis: axis)
        activeGesture = active

        if axis == .vertical {
            publishVerticalSwipePreview(active, deltaY: totalY)
        }
        return .compositor(redrawOutputID: nil)
    }

    private func updatePinch(
        _ sequence: NormalizedGestureSequence,
        scale: Double,
        target: GesturePolicyTarget?
    ) -> GesturePolicyOutcome {
        guard capturedSequences.contains(sequence) else { return .client }
        guard var active = validActiveGesture(sequence: sequence, target: target),
            case .pinch = active.interaction
        else { return .compositor(redrawOutputID: nil) }

        active.interaction = .pinch(scale: scale)
        activeGesture = active
        publishPinchPreview(active, scale: scale)
        return .compositor(redrawOutputID: nil)
    }

    private func end(
        _ sequence: NormalizedGestureSequence,
        cancelled: Bool,
        target: GesturePolicyTarget?
    ) -> GesturePolicyOutcome {
        guard capturedSequences.remove(sequence) != nil else { return .client }
        guard let active = validActiveGesture(sequence: sequence, target: target) else {
            return .compositor(redrawOutputID: nil)
        }
        activeGesture = nil
        if cancelled {
            restoreOverview(active)
            return .compositor(redrawOutputID: nil)
        }

        switch active.interaction {
        case .swipe(let deltaX, let deltaY, let axis):
            if axis == .horizontal, abs(deltaX) >= Self.swipeCommitDistance {
                restoreOverview(active)
                let changed = switchSpace(
                    on: active.target.outputID,
                    direction: deltaX < 0 ? 1 : -1)
                return .compositor(
                    redrawOutputID: changed ? active.target.outputID : nil)
            }
            if axis == .vertical, abs(deltaY) >= Self.swipeCommitDistance {
                commitOverview(
                    deltaY < 0 ? .windows : nil,
                    on: active.target.outputID)
            } else {
                restoreOverview(active)
            }
        case .pinch(let scale):
            if scale <= Self.pinchCommitScaleIn {
                commitOverview(.spaces, on: active.target.outputID)
            } else if scale >= Self.pinchCommitScaleOut {
                commitOverview(nil, on: active.target.outputID)
            } else {
                restoreOverview(active)
            }
        }
        return .compositor(redrawOutputID: nil)
    }

    private func isBound(_ sequence: NormalizedGestureSequence) -> Bool {
        switch (sequence.kind, sequence.fingerCount) {
        case (.swipe, 3), (.pinch, 4): true
        default: false
        }
    }

    private func outputExists(_ outputID: DisplayID) -> Bool {
        server.layout.display(id: outputID) != nil
    }

    private func validActiveGesture(
        sequence: NormalizedGestureSequence,
        target: GesturePolicyTarget?
    ) -> ActiveGesture? {
        guard let active = activeGesture, active.sequence == sequence else { return nil }
        guard target == active.target, outputExists(active.target.outputID) else {
            rollbackActiveGesture()
            return nil
        }
        return active
    }

    private func rollbackActiveGesture() {
        guard let active = activeGesture else { return }
        activeGesture = nil
        restoreOverview(active)
    }

    private func lockedAxis(deltaX: Double, deltaY: Double) -> SwipeAxis? {
        let x = abs(deltaX)
        let y = abs(deltaY)
        guard max(x, y) >= Self.axisLockDistance else { return nil }
        if x >= y * Self.axisDominance { return .horizontal }
        if y >= x * Self.axisDominance { return .vertical }
        return nil
    }

    private func switchSpace(on outputID: DisplayID, direction: Int) -> Bool {
        let spaces = server.spaces.spaces(forOutput: outputID)
        guard let activeID = server.spaces.activeSpace(forDisplay: outputID),
            let index = spaces.firstIndex(where: { $0.id == activeID })
        else { return false }
        let destination = index + direction
        guard spaces.indices.contains(destination) else { return false }
        return server.spaces.setActiveSpace(spaces[destination].id, forDisplay: outputID)
    }

    private func publishVerticalSwipePreview(
        _ active: ActiveGesture,
        deltaY: Double
    ) {
        let opening = deltaY < 0
        let originalVisible = active.originalOverview == .windows
        guard opening || originalVisible else {
            restoreOverview(active)
            return
        }
        let transition = min(abs(deltaY) / Self.swipeCommitDistance, 1)
        publishOverview(
            .windows,
            outputID: active.target.outputID,
            progress: opening ? transition : 1 - transition,
            interactive: true)
    }

    private func publishPinchPreview(_ active: ActiveGesture, scale: Double) {
        let opening = scale < 1
        let originalVisible = active.originalOverview == .spaces
        guard opening || originalVisible else {
            restoreOverview(active)
            return
        }
        let transition = min(abs(scale - 1) / 0.25, 1)
        publishOverview(
            .spaces,
            outputID: active.target.outputID,
            progress: opening ? transition : 1 - transition,
            interactive: true)
    }

    private func restoreOverview(_ active: ActiveGesture) {
        commitOverview(active.originalOverview, on: active.target.outputID)
    }

    private func commitOverview(
        _ kind: CompositorOverviewKind?,
        on outputID: DisplayID
    ) {
        overviewByOutput[outputID] = kind
        if let kind {
            publishOverview(
                kind, outputID: outputID, progress: 1, interactive: false)
        } else {
            overviewSink?(outputID, nil)
        }
    }

    private func publishOverview(
        _ kind: CompositorOverviewKind,
        outputID: DisplayID,
        progress: Double,
        interactive: Bool
    ) {
        overviewSink?(
            outputID,
            CompositorOverviewState(
                kind: kind,
                outputID: outputID,
                progress: min(max(progress, 0), 1),
                interactive: interactive))
    }
}
