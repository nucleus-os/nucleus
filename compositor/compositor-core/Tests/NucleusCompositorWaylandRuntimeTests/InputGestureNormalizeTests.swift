import NucleusCompositorServerTypes
import Testing

@testable import NucleusCompositorWaylandRuntime

@Suite struct InputGestureNormalizeTests {
    private let firstDevice = NormalizedGestureDeviceID(rawValue: 11)
    private let secondDevice = NormalizedGestureDeviceID(rawValue: 22)

    @Test func swipeLifecyclePreservesTypedValues() {
        var normalizer = GestureSequenceNormalizer()
        let sequence = NormalizedGestureSequence(
            deviceID: firstDevice,
            kind: .swipe,
            fingerCount: 3)

        #expect(
            normalizer.normalize(
                .began(
                    deviceID: firstDevice,
                    kind: .swipe,
                    fingerCount: 3,
                    timestampNs: 10))
                == [.began(sequence: sequence, timestampNs: 10)])
        #expect(
            normalizer.normalize(
                .swipeUpdated(
                    deviceID: firstDevice,
                    timestampNs: 20,
                    deltaX: 1.25,
                    deltaY: -2.5))
                == [
                    .swipeUpdated(
                        sequence: sequence,
                        timestampNs: 20,
                        deltaX: 1.25,
                        deltaY: -2.5)
                ])
        #expect(
            normalizer.normalize(
                .ended(
                    deviceID: firstDevice,
                    kind: .swipe,
                    timestampNs: 30,
                    cancelled: false))
                == [
                    .ended(
                        sequence: sequence,
                        timestampNs: 30,
                        cancelled: false)
                ])
    }

    @Test func pinchAndHoldUseTheirOwnPayloadShapes() {
        var normalizer = GestureSequenceNormalizer()
        let pinch = NormalizedGestureSequence(
            deviceID: firstDevice,
            kind: .pinch,
            fingerCount: 4)
        let hold = NormalizedGestureSequence(
            deviceID: secondDevice,
            kind: .hold,
            fingerCount: 2)

        #expect(
            normalizer.normalize(
                .began(
                    deviceID: firstDevice,
                    kind: .pinch,
                    fingerCount: 4,
                    timestampNs: 100))
                == [.began(sequence: pinch, timestampNs: 100)])
        #expect(
            normalizer.normalize(
                .pinchUpdated(
                    deviceID: firstDevice,
                    timestampNs: 110,
                    deltaX: 3,
                    deltaY: 5,
                    scale: 0.75,
                    rotationDegrees: -12))
                == [
                    .pinchUpdated(
                        sequence: pinch,
                        timestampNs: 110,
                        deltaX: 3,
                        deltaY: 5,
                        scale: 0.75,
                        rotationDegrees: -12)
                ])
        #expect(
            normalizer.normalize(
                .began(
                    deviceID: secondDevice,
                    kind: .hold,
                    fingerCount: 2,
                    timestampNs: 120))
                == [.began(sequence: hold, timestampNs: 120)])
        #expect(
            normalizer.normalize(
                .ended(
                    deviceID: secondDevice,
                    kind: .hold,
                    timestampNs: 130,
                    cancelled: true))
                == [
                    .ended(
                        sequence: hold,
                        timestampNs: 130,
                        cancelled: true)
                ])
    }

    @Test func malformedTransitionCancelsTheActiveSequence() {
        var normalizer = GestureSequenceNormalizer()
        let sequence = NormalizedGestureSequence(
            deviceID: firstDevice,
            kind: .swipe,
            fingerCount: 3)
        _ = normalizer.normalize(
            .began(
                deviceID: firstDevice,
                kind: .swipe,
                fingerCount: 3,
                timestampNs: 40))

        #expect(
            normalizer.normalize(
                .pinchUpdated(
                    deviceID: firstDevice,
                    timestampNs: 50,
                    deltaX: 0,
                    deltaY: 0,
                    scale: 1,
                    rotationDegrees: 0))
                == [
                    .ended(
                        sequence: sequence,
                        timestampNs: 50,
                        cancelled: true)
                ])
        #expect(
            normalizer.normalize(
                .ended(
                    deviceID: firstDevice,
                    kind: .swipe,
                    timestampNs: 60,
                    cancelled: false)
            ).isEmpty)
    }

    @Test func repeatedBeginCancelsRatherThanReplacingOwnership() {
        var normalizer = GestureSequenceNormalizer()
        let sequence = NormalizedGestureSequence(
            deviceID: firstDevice,
            kind: .hold,
            fingerCount: 2)
        _ = normalizer.normalize(
            .began(
                deviceID: firstDevice,
                kind: .hold,
                fingerCount: 2,
                timestampNs: 70))

        #expect(
            normalizer.normalize(
                .began(
                    deviceID: firstDevice,
                    kind: .swipe,
                    fingerCount: 3,
                    timestampNs: 80))
                == [
                    .ended(
                        sequence: sequence,
                        timestampNs: 80,
                        cancelled: true)
                ])
        #expect(normalizer.cancelAll().isEmpty)
    }

    @Test func devicesOwnIndependentSequencesAndRemovalCancelsOnlyOne() {
        var normalizer = GestureSequenceNormalizer()
        let first = NormalizedGestureSequence(
            deviceID: firstDevice,
            kind: .swipe,
            fingerCount: 3)
        let second = NormalizedGestureSequence(
            deviceID: secondDevice,
            kind: .hold,
            fingerCount: 2)
        _ = normalizer.normalize(
            .began(
                deviceID: firstDevice,
                kind: .swipe,
                fingerCount: 3,
                timestampNs: 100))
        _ = normalizer.normalize(
            .began(
                deviceID: secondDevice,
                kind: .hold,
                fingerCount: 2,
                timestampNs: 200))

        #expect(
            normalizer.deviceRemoved(firstDevice)
                == .ended(sequence: first, timestampNs: 100, cancelled: true))
        #expect(
            normalizer.cancelAll()
                == [.ended(sequence: second, timestampNs: 200, cancelled: true)])
    }

    @Test func invalidNumericAndRegressingTimeCancelMonotonically() {
        var normalizer = GestureSequenceNormalizer()
        let sequence = NormalizedGestureSequence(
            deviceID: firstDevice,
            kind: .pinch,
            fingerCount: 4)
        _ = normalizer.normalize(
            .began(
                deviceID: firstDevice,
                kind: .pinch,
                fingerCount: 4,
                timestampNs: 500))

        #expect(
            normalizer.normalize(
                .pinchUpdated(
                    deviceID: firstDevice,
                    timestampNs: 490,
                    deltaX: 0,
                    deltaY: 0,
                    scale: .nan,
                    rotationDegrees: 0))
                == [
                    .ended(
                        sequence: sequence,
                        timestampNs: 500,
                        cancelled: true)
                ])
        #expect(
            normalizer.normalize(
                .began(
                    deviceID: secondDevice,
                    kind: .swipe,
                    fingerCount: 0,
                    timestampNs: 600)
            ).isEmpty)
    }
}
