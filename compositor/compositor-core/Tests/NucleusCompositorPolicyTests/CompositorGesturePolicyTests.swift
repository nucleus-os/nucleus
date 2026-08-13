import NucleusCompositorServer
import NucleusCompositorServerTypes
import Testing

@testable import NucleusCompositorPolicy

@Suite
@MainActor
struct CompositorGesturePolicyTests {
    private let device = NormalizedGestureDeviceID(rawValue: 1)

    @Test func horizontalSwipeSwitchesSpacesOnlyAfterThreshold() throws {
        let (server, policy, target) = try makePolicy(spaceCount: 3)
        let spaces = server.spaces.spaces(forOutput: target.outputID)

        let belowThreshold = sequence(.swipe, fingers: 3)
        #expect(
            isCompositor(
                policy.dispatch(.began(sequence: belowThreshold, timestampNs: 1), target: target)))
        #expect(
            isCompositor(
                policy.dispatch(
                    .swipeUpdated(
                        sequence: belowThreshold, timestampNs: 2,
                        deltaX: -119, deltaY: 0),
                    target: target)))
        _ = policy.dispatch(
            .ended(sequence: belowThreshold, timestampNs: 3, cancelled: false),
            target: target)
        #expect(server.spaces.activeSpace(forDisplay: target.outputID) == spaces[0].id)

        let next = sequence(.swipe, fingers: 3)
        _ = policy.dispatch(.began(sequence: next, timestampNs: 4), target: target)
        _ = policy.dispatch(
            .swipeUpdated(sequence: next, timestampNs: 5, deltaX: -120, deltaY: 0),
            target: target)
        let outcome = policy.dispatch(
            .ended(sequence: next, timestampNs: 6, cancelled: false),
            target: target)
        #expect(outcome == .compositor(redrawOutputID: target.outputID))
        #expect(server.spaces.activeSpace(forDisplay: target.outputID) == spaces[1].id)

        let previous = sequence(.swipe, fingers: 3)
        _ = policy.dispatch(.began(sequence: previous, timestampNs: 7), target: target)
        _ = policy.dispatch(
            .swipeUpdated(sequence: previous, timestampNs: 8, deltaX: 120, deltaY: 0),
            target: target)
        _ = policy.dispatch(
            .ended(sequence: previous, timestampNs: 9, cancelled: false),
            target: target)
        #expect(server.spaces.activeSpace(forDisplay: target.outputID) == spaces[0].id)
    }

    @Test func swipeDirectionLocksOnlyWhenOneAxisDominates() throws {
        let (server, policy, target) = try makePolicy(spaceCount: 2)
        let spaces = server.spaces.spaces(forOutput: target.outputID)
        let gesture = sequence(.swipe, fingers: 3)

        _ = policy.dispatch(.began(sequence: gesture, timestampNs: 1), target: target)
        _ = policy.dispatch(
            .swipeUpdated(sequence: gesture, timestampNs: 2, deltaX: -120, deltaY: -100),
            target: target)
        _ = policy.dispatch(
            .ended(sequence: gesture, timestampNs: 3, cancelled: false),
            target: target)

        #expect(server.spaces.activeSpace(forDisplay: target.outputID) == spaces[0].id)
        #expect(policy.overview(on: target.outputID) == nil)
    }

    @Test func verticalSwipePublishesPreviewAndCancellationRollsBack() throws {
        let (_, policy, target) = try makePolicy()
        var updates: [CompositorOverviewState?] = []
        policy.overviewSink = { outputID, state in
            #expect(outputID == target.outputID)
            updates.append(state)
        }
        let gesture = sequence(.swipe, fingers: 3)

        _ = policy.dispatch(.began(sequence: gesture, timestampNs: 1), target: target)
        _ = policy.dispatch(
            .swipeUpdated(sequence: gesture, timestampNs: 2, deltaX: 0, deltaY: -60),
            target: target)
        #expect(
            updates.last
                == CompositorOverviewState(
                    kind: .windows, outputID: target.outputID,
                    progress: 0.5, interactive: true))
        _ = policy.dispatch(
            .ended(sequence: gesture, timestampNs: 3, cancelled: true),
            target: target)

        #expect(policy.overview(on: target.outputID) == nil)
        #expect(updates.count == 2)
        #expect(updates[1] == nil)
    }

    @Test func verticalSwipeCommitsAndReverseSwipeClosesWindowsOverview() throws {
        let (_, policy, target) = try makePolicy()
        let open = sequence(.swipe, fingers: 3)
        _ = policy.dispatch(.began(sequence: open, timestampNs: 1), target: target)
        _ = policy.dispatch(
            .swipeUpdated(sequence: open, timestampNs: 2, deltaX: 0, deltaY: -120),
            target: target)
        _ = policy.dispatch(
            .ended(sequence: open, timestampNs: 3, cancelled: false),
            target: target)
        #expect(policy.overview(on: target.outputID) == .windows)

        let close = sequence(.swipe, fingers: 3)
        _ = policy.dispatch(.began(sequence: close, timestampNs: 4), target: target)
        _ = policy.dispatch(
            .swipeUpdated(sequence: close, timestampNs: 5, deltaX: 0, deltaY: 120),
            target: target)
        _ = policy.dispatch(
            .ended(sequence: close, timestampNs: 6, cancelled: false),
            target: target)
        #expect(policy.overview(on: target.outputID) == nil)
    }

    @Test func fourFingerPinchOwnsSpacesOverviewAndTwoFingerPinchForwards() throws {
        let (_, policy, target) = try makePolicy()
        let twoFinger = sequence(.pinch, fingers: 2)
        #expect(
            policy.dispatch(
                .began(sequence: twoFinger, timestampNs: 1),
                target: target) == .client)
        #expect(
            policy.dispatch(
                .pinchUpdated(
                    sequence: twoFinger, timestampNs: 2, deltaX: 0, deltaY: 0,
                    scale: 0.5, rotationDegrees: 0),
                target: target) == .client)
        #expect(
            policy.dispatch(
                .ended(sequence: twoFinger, timestampNs: 3, cancelled: false),
                target: target) == .client)

        let fourFinger = sequence(.pinch, fingers: 4)
        _ = policy.dispatch(.began(sequence: fourFinger, timestampNs: 4), target: target)
        _ = policy.dispatch(
            .pinchUpdated(
                sequence: fourFinger, timestampNs: 5, deltaX: 0, deltaY: 0,
                scale: 0.75, rotationDegrees: 0),
            target: target)
        _ = policy.dispatch(
            .ended(sequence: fourFinger, timestampNs: 6, cancelled: false),
            target: target)
        #expect(policy.overview(on: target.outputID) == .spaces)
    }

    @Test func holdAndGesturesWithNoTargetRemainClientOwned() throws {
        let (_, policy, target) = try makePolicy()
        let hold = sequence(.hold, fingers: 3)
        #expect(
            policy.dispatch(
                .began(sequence: hold, timestampNs: 1),
                target: target) == .client)

        let swipe = sequence(.swipe, fingers: 3)
        #expect(
            policy.dispatch(
                .began(sequence: swipe, timestampNs: 2),
                target: nil) == .client)
    }

    @Test func focusChangeRollsBackWithoutForwardingTheCapturedTail() throws {
        let (_, policy, target) = try makePolicy()
        let gesture = sequence(.swipe, fingers: 3)
        _ = policy.dispatch(.began(sequence: gesture, timestampNs: 1), target: target)
        _ = policy.dispatch(
            .swipeUpdated(sequence: gesture, timestampNs: 2, deltaX: 0, deltaY: -60),
            target: target)

        let changedTarget = GesturePolicyTarget(
            surfaceID: WlSurfaceID(11), outputID: target.outputID)
        #expect(
            isCompositor(
                policy.dispatch(
                    .swipeUpdated(sequence: gesture, timestampNs: 3, deltaX: 0, deltaY: -60),
                    target: changedTarget)))
        #expect(policy.overview(on: target.outputID) == nil)
        #expect(
            isCompositor(
                policy.dispatch(
                    .ended(sequence: gesture, timestampNs: 4, cancelled: false),
                    target: changedTarget)))
    }

    @Test func spaceSwitchUsesTheActiveSpaceAtCommitTime() throws {
        let (server, policy, target) = try makePolicy(spaceCount: 3)
        let spaces = server.spaces.spaces(forOutput: target.outputID)
        let gesture = sequence(.swipe, fingers: 3)
        _ = policy.dispatch(.began(sequence: gesture, timestampNs: 1), target: target)
        _ = policy.dispatch(
            .swipeUpdated(sequence: gesture, timestampNs: 2, deltaX: -120, deltaY: 0),
            target: target)

        _ = server.spaces.setActiveSpace(spaces[1].id, forDisplay: target.outputID)
        _ = policy.dispatch(
            .ended(sequence: gesture, timestampNs: 3, cancelled: false),
            target: target)
        #expect(server.spaces.activeSpace(forDisplay: target.outputID) == spaces[2].id)
    }

    @Test func outputRemovalDiscardsPreviewAndCommittedOverviewState() throws {
        let (_, policy, target) = try makePolicy()
        let gesture = sequence(.swipe, fingers: 3)
        _ = policy.dispatch(.began(sequence: gesture, timestampNs: 1), target: target)
        _ = policy.dispatch(
            .swipeUpdated(sequence: gesture, timestampNs: 2, deltaX: 0, deltaY: -60),
            target: target)

        policy.outputWillRemove(target.outputID)
        #expect(policy.overview(on: target.outputID) == nil)
        #expect(
            isCompositor(
                policy.dispatch(
                    .ended(sequence: gesture, timestampNs: 3, cancelled: false),
                    target: target)))
    }

    @Test func explicitCancellationRestoresTheOriginalOverview() throws {
        let (_, policy, target) = try makePolicy()
        let open = sequence(.pinch, fingers: 4)
        _ = policy.dispatch(.began(sequence: open, timestampNs: 1), target: target)
        _ = policy.dispatch(
            .pinchUpdated(
                sequence: open, timestampNs: 2, deltaX: 0, deltaY: 0,
                scale: 0.75, rotationDegrees: 0),
            target: target)
        _ = policy.dispatch(
            .ended(sequence: open, timestampNs: 3, cancelled: false),
            target: target)

        let closing = sequence(.pinch, fingers: 4)
        _ = policy.dispatch(.began(sequence: closing, timestampNs: 4), target: target)
        _ = policy.dispatch(
            .pinchUpdated(
                sequence: closing, timestampNs: 5, deltaX: 0, deltaY: 0,
                scale: 1.2, rotationDegrees: 0),
            target: target)
        policy.cancelActiveGesture()
        #expect(policy.overview(on: target.outputID) == .spaces)
    }

    private func makePolicy(
        spaceCount: Int = 1
    ) throws -> (NucleusCompositorServer, CompositorGesturePolicy, GesturePolicyTarget) {
        let server = NucleusCompositorServer()
        var mode = WireDisplayMode()
        mode.pixelWidth = 1920
        mode.pixelHeight = 1080
        mode.refreshMhz = 60_000
        var configuration = WireDisplayConfiguration()
        configuration.enabled = true
        configuration.primary = true
        configuration.scale = 1
        configuration.fractionalScale = 1
        configuration.mode = mode
        try server.displayAdd(id: 7, configuration: configuration)
        for _ in 1..<spaceCount {
            _ = server.spaces.appendWorkspace(onOutput: 7)
        }
        let policy = CompositorGesturePolicy(server: server)
        return (
            server,
            policy,
            GesturePolicyTarget(surfaceID: WlSurfaceID(10), outputID: 7)
        )
    }

    private func sequence(
        _ kind: NormalizedGestureKind,
        fingers: UInt32
    ) -> NormalizedGestureSequence {
        NormalizedGestureSequence(
            deviceID: device, kind: kind, fingerCount: fingers)
    }

    private func isCompositor(_ outcome: GesturePolicyOutcome) -> Bool {
        if case .compositor = outcome { return true }
        return false
    }
}
