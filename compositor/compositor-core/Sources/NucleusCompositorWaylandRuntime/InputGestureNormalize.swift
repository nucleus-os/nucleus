import NucleusCompositorInputC
import NucleusCompositorServerTypes

enum GestureInputSample: Equatable {
    case began(
        deviceID: NormalizedGestureDeviceID,
        kind: NormalizedGestureKind,
        fingerCount: UInt32,
        timestampNs: UInt64)
    case swipeUpdated(
        deviceID: NormalizedGestureDeviceID,
        timestampNs: UInt64,
        deltaX: Double,
        deltaY: Double)
    case pinchUpdated(
        deviceID: NormalizedGestureDeviceID,
        timestampNs: UInt64,
        deltaX: Double,
        deltaY: Double,
        scale: Double,
        rotationDegrees: Double)
    case ended(
        deviceID: NormalizedGestureDeviceID,
        kind: NormalizedGestureKind,
        timestampNs: UInt64,
        cancelled: Bool)

    var deviceID: NormalizedGestureDeviceID {
        switch self {
        case .began(let deviceID, _, _, _),
            .swipeUpdated(let deviceID, _, _, _),
            .pinchUpdated(let deviceID, _, _, _, _, _),
            .ended(let deviceID, _, _, _):
            return deviceID
        }
    }

    var timestampNs: UInt64 {
        switch self {
        case .began(_, _, _, let timestampNs),
            .swipeUpdated(_, let timestampNs, _, _),
            .pinchUpdated(_, let timestampNs, _, _, _, _),
            .ended(_, _, let timestampNs, _):
            return timestampNs
        }
    }
}

struct GestureSequenceNormalizer {
    private struct ActiveGesture {
        let sequence: NormalizedGestureSequence
        var lastTimestampNs: UInt64
    }

    private var activeByDevice: [NormalizedGestureDeviceID: ActiveGesture] = [:]

    mutating func normalize(_ sample: GestureInputSample) -> [NormalizedGestureEvent] {
        switch sample {
        case .began(let deviceID, let kind, let fingerCount, let timestampNs):
            guard activeByDevice[deviceID] == nil else {
                return cancel(deviceID: deviceID, at: timestampNs).map { [$0] } ?? []
            }
            guard fingerCount > 0 else { return [] }
            let sequence = NormalizedGestureSequence(
                deviceID: deviceID,
                kind: kind,
                fingerCount: fingerCount)
            activeByDevice[deviceID] = ActiveGesture(
                sequence: sequence,
                lastTimestampNs: timestampNs)
            return [.began(sequence: sequence, timestampNs: timestampNs)]

        case .swipeUpdated(let deviceID, let timestampNs, let deltaX, let deltaY):
            guard deltaX.isFinite, deltaY.isFinite else {
                return cancel(deviceID: deviceID, at: timestampNs).map { [$0] } ?? []
            }
            guard
                let active = acceptUpdate(
                    deviceID: deviceID,
                    kind: .swipe,
                    timestampNs: timestampNs)
            else {
                return cancel(deviceID: deviceID, at: timestampNs).map { [$0] } ?? []
            }
            return [
                .swipeUpdated(
                    sequence: active.sequence,
                    timestampNs: timestampNs,
                    deltaX: deltaX,
                    deltaY: deltaY)
            ]

        case .pinchUpdated(
            let deviceID,
            let timestampNs,
            let deltaX,
            let deltaY,
            let scale,
            let rotationDegrees
        ):
            guard deltaX.isFinite, deltaY.isFinite, scale.isFinite, scale > 0,
                rotationDegrees.isFinite
            else {
                return cancel(deviceID: deviceID, at: timestampNs).map { [$0] } ?? []
            }
            guard
                let active = acceptUpdate(
                    deviceID: deviceID,
                    kind: .pinch,
                    timestampNs: timestampNs)
            else {
                return cancel(deviceID: deviceID, at: timestampNs).map { [$0] } ?? []
            }
            return [
                .pinchUpdated(
                    sequence: active.sequence,
                    timestampNs: timestampNs,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    scale: scale,
                    rotationDegrees: rotationDegrees)
            ]

        case .ended(let deviceID, let kind, let timestampNs, let cancelled):
            guard let active = activeByDevice[deviceID],
                active.sequence.kind == kind,
                timestampNs >= active.lastTimestampNs
            else {
                return cancel(deviceID: deviceID, at: timestampNs).map { [$0] } ?? []
            }
            activeByDevice.removeValue(forKey: deviceID)
            return [
                .ended(
                    sequence: active.sequence,
                    timestampNs: timestampNs,
                    cancelled: cancelled)
            ]
        }
    }

    mutating func deviceRemoved(_ deviceID: NormalizedGestureDeviceID) -> NormalizedGestureEvent? {
        cancel(deviceID: deviceID, at: nil)
    }

    mutating func cancelAll() -> [NormalizedGestureEvent] {
        let deviceIDs = activeByDevice.keys.sorted()
        return deviceIDs.compactMap { cancel(deviceID: $0, at: nil) }
    }

    private mutating func acceptUpdate(
        deviceID: NormalizedGestureDeviceID,
        kind: NormalizedGestureKind,
        timestampNs: UInt64
    ) -> ActiveGesture? {
        guard var active = activeByDevice[deviceID],
            active.sequence.kind == kind,
            timestampNs >= active.lastTimestampNs
        else { return nil }
        active.lastTimestampNs = timestampNs
        activeByDevice[deviceID] = active
        return active
    }

    private mutating func cancel(
        deviceID: NormalizedGestureDeviceID,
        at timestampNs: UInt64?
    ) -> NormalizedGestureEvent? {
        guard let active = activeByDevice.removeValue(forKey: deviceID) else { return nil }
        return .ended(
            sequence: active.sequence,
            timestampNs: max(timestampNs ?? active.lastTimestampNs, active.lastTimestampNs),
            cancelled: true)
    }
}

enum InputGestureNormalize {
    @unsafe static func translate(_ event: OpaquePointer) -> GestureInputSample? {
        let type = unsafe libinput_event_get_type(event)
        guard isGesture(type),
            let gesture = unsafe libinput_event_get_gesture_event(event),
            let device = unsafe libinput_event_get_device(event)
        else { return nil }

        let deviceID = unsafe NormalizedGestureDeviceID(
            rawValue: UInt64(UInt(bitPattern: UnsafeRawPointer(device))))
        let timestampNs = unsafe libinput_event_gesture_get_time_usec(gesture) &* 1_000

        switch type {
        case LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN:
            return unsafe .began(
                deviceID: deviceID,
                kind: .swipe,
                fingerCount: UInt32(libinput_event_gesture_get_finger_count(gesture)),
                timestampNs: timestampNs)
        case LIBINPUT_EVENT_GESTURE_PINCH_BEGIN:
            return unsafe .began(
                deviceID: deviceID,
                kind: .pinch,
                fingerCount: UInt32(libinput_event_gesture_get_finger_count(gesture)),
                timestampNs: timestampNs)
        case LIBINPUT_EVENT_GESTURE_HOLD_BEGIN:
            return unsafe .began(
                deviceID: deviceID,
                kind: .hold,
                fingerCount: UInt32(libinput_event_gesture_get_finger_count(gesture)),
                timestampNs: timestampNs)
        case LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE:
            return unsafe .swipeUpdated(
                deviceID: deviceID,
                timestampNs: timestampNs,
                deltaX: libinput_event_gesture_get_dx(gesture),
                deltaY: libinput_event_gesture_get_dy(gesture))
        case LIBINPUT_EVENT_GESTURE_PINCH_UPDATE:
            return unsafe .pinchUpdated(
                deviceID: deviceID,
                timestampNs: timestampNs,
                deltaX: libinput_event_gesture_get_dx(gesture),
                deltaY: libinput_event_gesture_get_dy(gesture),
                scale: libinput_event_gesture_get_scale(gesture),
                rotationDegrees: libinput_event_gesture_get_angle_delta(gesture))
        case LIBINPUT_EVENT_GESTURE_SWIPE_END:
            return unsafe .ended(
                deviceID: deviceID,
                kind: .swipe,
                timestampNs: timestampNs,
                cancelled: libinput_event_gesture_get_cancelled(gesture) != 0)
        case LIBINPUT_EVENT_GESTURE_PINCH_END:
            return unsafe .ended(
                deviceID: deviceID,
                kind: .pinch,
                timestampNs: timestampNs,
                cancelled: libinput_event_gesture_get_cancelled(gesture) != 0)
        case LIBINPUT_EVENT_GESTURE_HOLD_END:
            return unsafe .ended(
                deviceID: deviceID,
                kind: .hold,
                timestampNs: timestampNs,
                cancelled: libinput_event_gesture_get_cancelled(gesture) != 0)
        default:
            return nil
        }
    }

    private static func isGesture(_ type: libinput_event_type) -> Bool {
        switch type {
        case LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN,
            LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE,
            LIBINPUT_EVENT_GESTURE_SWIPE_END,
            LIBINPUT_EVENT_GESTURE_PINCH_BEGIN,
            LIBINPUT_EVENT_GESTURE_PINCH_UPDATE,
            LIBINPUT_EVENT_GESTURE_PINCH_END,
            LIBINPUT_EVENT_GESTURE_HOLD_BEGIN,
            LIBINPUT_EVENT_GESTURE_HOLD_END:
            return true
        default:
            return false
        }
    }
}
