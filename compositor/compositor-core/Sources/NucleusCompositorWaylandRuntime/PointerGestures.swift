import NucleusCompositorServerTypes
import WaylandServer
import WaylandServerDispatch

@MainActor
@safe final class PointerGestureManager: ZwpPointerGesturesV1Requests {
    private unowned let seat: WlSeat
    private var swipes = WeakObjectList<PointerSwipeGesture>()
    private var pinches = WeakObjectList<PointerPinchGesture>()
    private var holds = WeakObjectList<PointerHoldGesture>()
    private var activeSequence: NormalizedGestureSequence?
    private var lastTimestampNs: UInt64 = 0

    init(seat: WlSeat) {
        self.seat = seat
    }

    func getSwipeGesture(
        _ request: WaylandRequest<ZwpPointerGesturesV1Server>,
        id: WlNewId<ZwpPointerGestureSwipeV1Server>,
        pointer: WaylandBorrowedObject<WlPointerServer>
    ) {
        guard let pointer = ownedPointer(pointer, clientID: id.clientID) else { return }
        _ = id.create(
            owner: { handle in
                PointerSwipeGesture(resource: handle, manager: self, pointer: pointer)
            },
            installed: { self.swipes.append($0) })
    }

    func getPinchGesture(
        _ request: WaylandRequest<ZwpPointerGesturesV1Server>,
        id: WlNewId<ZwpPointerGesturePinchV1Server>,
        pointer: WaylandBorrowedObject<WlPointerServer>
    ) {
        guard let pointer = ownedPointer(pointer, clientID: id.clientID) else { return }
        _ = id.create(
            owner: { handle in
                PointerPinchGesture(resource: handle, manager: self, pointer: pointer)
            },
            installed: { self.pinches.append($0) })
    }

    func getHoldGesture(
        _ request: WaylandRequest<ZwpPointerGesturesV1Server>,
        id: WlNewId<ZwpPointerGestureHoldV1Server>,
        pointer: WaylandBorrowedObject<WlPointerServer>
    ) {
        guard let pointer = ownedPointer(pointer, clientID: id.clientID) else { return }
        _ = id.create(
            owner: { handle in
                PointerHoldGesture(resource: handle, manager: self, pointer: pointer)
            },
            installed: { self.holds.append($0) })
    }

    func handle(_ event: NormalizedGestureEvent) {
        switch event {
        case .began(let sequence, let timestampNs):
            begin(sequence, timestampNs: timestampNs)
        case .swipeUpdated(let sequence, let timestampNs, let deltaX, let deltaY):
            guard activeSequence == sequence else { return }
            lastTimestampNs = max(lastTimestampNs, timestampNs)
            swipes.forEach {
                $0.sendUpdate(
                    sequence: sequence,
                    timestampMs: Self.timestampMs(timestampNs),
                    deltaX: deltaX,
                    deltaY: deltaY)
            }
        case .pinchUpdated(
            let sequence,
            let timestampNs,
            let deltaX,
            let deltaY,
            let scale,
            let rotationDegrees
        ):
            guard activeSequence == sequence else { return }
            lastTimestampNs = max(lastTimestampNs, timestampNs)
            pinches.forEach {
                $0.sendUpdate(
                    sequence: sequence,
                    timestampMs: Self.timestampMs(timestampNs),
                    deltaX: deltaX,
                    deltaY: deltaY,
                    scale: scale,
                    rotationDegrees: rotationDegrees)
            }
        case .ended(let sequence, let timestampNs, let cancelled):
            guard activeSequence == sequence else { return }
            end(sequence, timestampNs: timestampNs, cancelled: cancelled)
        }
    }

    func pointerFocusChanged() {
        cancelActiveSequence()
    }

    fileprivate func remove(_ gesture: PointerSwipeGesture) {
        swipes.remove(gesture)
        retireIfNoRecipientRemains()
    }

    fileprivate func remove(_ gesture: PointerPinchGesture) {
        pinches.remove(gesture)
        retireIfNoRecipientRemains()
    }

    fileprivate func remove(_ gesture: PointerHoldGesture) {
        holds.remove(gesture)
        retireIfNoRecipientRemains()
    }

    private func ownedPointer(
        _ object: WaylandBorrowedObject<WlPointerServer>,
        clientID: WaylandClientID
    ) -> WlPointer? {
        guard object.clientID == clientID,
            let pointer = object.owner(as: WlPointer.self),
            pointer.seat === seat
        else { return nil }
        return pointer
    }

    private func begin(_ sequence: NormalizedGestureSequence, timestampNs: UInt64) {
        cancelActiveSequence(at: timestampNs)
        guard let focus = seat.pointerGestureFocus else { return }
        let serial = seat.nextPointerGestureSerial()
        let timestampMs = Self.timestampMs(timestampNs)
        var sent = false
        switch sequence.kind {
        case .swipe:
            swipes.forEach {
                sent =
                    $0.sendBegin(
                        sequence: sequence,
                        clientID: focus.clientID,
                        serial: serial,
                        timestampMs: timestampMs,
                        surface: focus.surface) || sent
            }
        case .pinch:
            pinches.forEach {
                sent =
                    $0.sendBegin(
                        sequence: sequence,
                        clientID: focus.clientID,
                        serial: serial,
                        timestampMs: timestampMs,
                        surface: focus.surface) || sent
            }
        case .hold:
            holds.forEach {
                sent =
                    $0.sendBegin(
                        sequence: sequence,
                        clientID: focus.clientID,
                        serial: serial,
                        timestampMs: timestampMs,
                        surface: focus.surface) || sent
            }
        }
        guard sent else { return }
        activeSequence = sequence
        lastTimestampNs = timestampNs
    }

    private func end(
        _ sequence: NormalizedGestureSequence,
        timestampNs: UInt64,
        cancelled: Bool
    ) {
        let boundedTimestamp = max(lastTimestampNs, timestampNs)
        let serial = seat.nextPointerGestureSerial()
        let timestampMs = Self.timestampMs(boundedTimestamp)
        switch sequence.kind {
        case .swipe:
            swipes.forEach {
                $0.sendEnd(
                    sequence: sequence,
                    serial: serial,
                    timestampMs: timestampMs,
                    cancelled: cancelled)
            }
        case .pinch:
            pinches.forEach {
                $0.sendEnd(
                    sequence: sequence,
                    serial: serial,
                    timestampMs: timestampMs,
                    cancelled: cancelled)
            }
        case .hold:
            holds.forEach {
                $0.sendEnd(
                    sequence: sequence,
                    serial: serial,
                    timestampMs: timestampMs,
                    cancelled: cancelled)
            }
        }
        activeSequence = nil
        lastTimestampNs = 0
    }

    private func cancelActiveSequence(at timestampNs: UInt64? = nil) {
        guard let activeSequence else { return }
        end(
            activeSequence,
            timestampNs: timestampNs ?? lastTimestampNs,
            cancelled: true)
    }

    private func retireIfNoRecipientRemains() {
        guard let activeSequence else { return }
        let hasRecipient: Bool
        switch activeSequence.kind {
        case .swipe:
            hasRecipient = swipes.first { $0.owns(activeSequence) } != nil
        case .pinch:
            hasRecipient = pinches.first { $0.owns(activeSequence) } != nil
        case .hold:
            hasRecipient = holds.first { $0.owns(activeSequence) } != nil
        }
        if !hasRecipient {
            self.activeSequence = nil
            lastTimestampNs = 0
        }
    }

    private static func timestampMs(_ timestampNs: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: timestampNs / 1_000_000)
    }
}

@MainActor
@safe final class PointerSwipeGesture: ZwpPointerGestureSwipeV1Requests {
    let resource: WaylandResourceHandle<ZwpPointerGestureSwipeV1Server>
    private weak var manager: PointerGestureManager?
    private weak var pointer: WlPointer?
    private var activeSequence: NormalizedGestureSequence?

    init(
        resource: WaylandResourceHandle<ZwpPointerGestureSwipeV1Server>,
        manager: PointerGestureManager,
        pointer: WlPointer
    ) {
        self.resource = resource
        self.manager = manager
        self.pointer = pointer
    }

    isolated deinit { manager?.remove(self) }

    func sendBegin(
        sequence: NormalizedGestureSequence,
        clientID: WaylandClientID,
        serial: UInt32,
        timestampMs: UInt32,
        surface: WaylandResourceHandle<WlSurfaceServer>
    ) -> Bool {
        guard pointer?.clientKey == clientID,
            resource.sendBegin(
                serial: serial,
                time: timestampMs,
                surface: surface,
                fingers: sequence.fingerCount)
        else { return false }
        activeSequence = sequence
        return true
    }

    func sendUpdate(
        sequence: NormalizedGestureSequence,
        timestampMs: UInt32,
        deltaX: Double,
        deltaY: Double
    ) {
        guard activeSequence == sequence else { return }
        _ = resource.sendUpdate(time: timestampMs, dx: deltaX, dy: deltaY)
    }

    func sendEnd(
        sequence: NormalizedGestureSequence,
        serial: UInt32,
        timestampMs: UInt32,
        cancelled: Bool
    ) {
        guard activeSequence == sequence else { return }
        activeSequence = nil
        _ = resource.sendEnd(
            serial: serial,
            time: timestampMs,
            cancelled: cancelled ? 1 : 0)
    }

    func owns(_ sequence: NormalizedGestureSequence) -> Bool {
        activeSequence == sequence
    }
}

@MainActor
@safe final class PointerPinchGesture: ZwpPointerGesturePinchV1Requests {
    let resource: WaylandResourceHandle<ZwpPointerGesturePinchV1Server>
    private weak var manager: PointerGestureManager?
    private weak var pointer: WlPointer?
    private var activeSequence: NormalizedGestureSequence?

    init(
        resource: WaylandResourceHandle<ZwpPointerGesturePinchV1Server>,
        manager: PointerGestureManager,
        pointer: WlPointer
    ) {
        self.resource = resource
        self.manager = manager
        self.pointer = pointer
    }

    isolated deinit { manager?.remove(self) }

    func sendBegin(
        sequence: NormalizedGestureSequence,
        clientID: WaylandClientID,
        serial: UInt32,
        timestampMs: UInt32,
        surface: WaylandResourceHandle<WlSurfaceServer>
    ) -> Bool {
        guard pointer?.clientKey == clientID,
            resource.sendBegin(
                serial: serial,
                time: timestampMs,
                surface: surface,
                fingers: sequence.fingerCount)
        else { return false }
        activeSequence = sequence
        return true
    }

    func sendUpdate(
        sequence: NormalizedGestureSequence,
        timestampMs: UInt32,
        deltaX: Double,
        deltaY: Double,
        scale: Double,
        rotationDegrees: Double
    ) {
        guard activeSequence == sequence else { return }
        _ = resource.sendUpdate(
            time: timestampMs,
            dx: deltaX,
            dy: deltaY,
            scale: scale,
            rotation: rotationDegrees)
    }

    func sendEnd(
        sequence: NormalizedGestureSequence,
        serial: UInt32,
        timestampMs: UInt32,
        cancelled: Bool
    ) {
        guard activeSequence == sequence else { return }
        activeSequence = nil
        _ = resource.sendEnd(
            serial: serial,
            time: timestampMs,
            cancelled: cancelled ? 1 : 0)
    }

    func owns(_ sequence: NormalizedGestureSequence) -> Bool {
        activeSequence == sequence
    }
}

@MainActor
@safe final class PointerHoldGesture: ZwpPointerGestureHoldV1Requests {
    let resource: WaylandResourceHandle<ZwpPointerGestureHoldV1Server>
    private weak var manager: PointerGestureManager?
    private weak var pointer: WlPointer?
    private var activeSequence: NormalizedGestureSequence?

    init(
        resource: WaylandResourceHandle<ZwpPointerGestureHoldV1Server>,
        manager: PointerGestureManager,
        pointer: WlPointer
    ) {
        self.resource = resource
        self.manager = manager
        self.pointer = pointer
    }

    isolated deinit { manager?.remove(self) }

    func sendBegin(
        sequence: NormalizedGestureSequence,
        clientID: WaylandClientID,
        serial: UInt32,
        timestampMs: UInt32,
        surface: WaylandResourceHandle<WlSurfaceServer>
    ) -> Bool {
        guard pointer?.clientKey == clientID,
            resource.sendBegin(
                serial: serial,
                time: timestampMs,
                surface: surface,
                fingers: sequence.fingerCount)
        else { return false }
        activeSequence = sequence
        return true
    }

    func sendEnd(
        sequence: NormalizedGestureSequence,
        serial: UInt32,
        timestampMs: UInt32,
        cancelled: Bool
    ) {
        guard activeSequence == sequence else { return }
        activeSequence = nil
        _ = resource.sendEnd(
            serial: serial,
            time: timestampMs,
            cancelled: cancelled ? 1 : 0)
    }

    func owns(_ sequence: NormalizedGestureSequence) -> Bool {
        activeSequence == sequence
    }
}
