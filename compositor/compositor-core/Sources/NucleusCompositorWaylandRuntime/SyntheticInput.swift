import NucleusCompositorServerTypes
import WaylandProtocolTypes
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

@MainActor
@safe final class VirtualKeyboardManager: ZwpVirtualKeyboardManagerV1Requests {
    private unowned let host: RouterHost
    private unowned let seat: WlSeat

    init(host: RouterHost, seat: WlSeat) {
        self.host = host
        self.seat = seat
    }

    func createVirtualKeyboard(
        _ request: WaylandRequest<ZwpVirtualKeyboardManagerV1Server>,
        seat borrowedSeat: WaylandBorrowedObject<WlSeatServer>,
        id: WlNewId<ZwpVirtualKeyboardV1Server>
    ) {
        guard borrowedSeat.clientID == id.clientID,
            borrowedSeat.owner(as: SeatBinding.self)?.seat === seat
        else {
            request.postError(.unauthorized, message: "seat is not owned by this client")
            return
        }
        _ = id.create(
            owner: { handle in
                VirtualKeyboard(resource: handle, host: self.host)
            })
    }
}

@MainActor
@safe final class VirtualKeyboard: ZwpVirtualKeyboardV1Requests {
    private let resource: WaylandResourceHandle<ZwpVirtualKeyboardV1Server>
    private unowned let host: RouterHost
    private var hasKeymap = false
    private var pressedKeys: Set<UInt32> = []
    private var retired = false

    init(
        resource: WaylandResourceHandle<ZwpVirtualKeyboardV1Server>,
        host: RouterHost
    ) {
        self.resource = resource
        self.host = host
    }

    isolated deinit { retire() }

    func keymap(
        _ request: WaylandRequest<ZwpVirtualKeyboardV1Server>,
        format: UInt32,
        fd: consuming WaylandOwnedFileDescriptor,
        size: UInt32
    ) {
        // XKB_V1 is the only format defined by the protocol. Installing it into
        // the compositor's one seat state also republishes it to every keyboard
        // client, preserving one interpretation of subsequent key codes.
        hasKeymap =
            format == 1
            && host.inputHost?.installVirtualKeymap(
                descriptor: fd.rawValue,
                size: size) == true
        if !hasKeymap {
            request.postError(.noKeymap, message: "a non-empty XKB_V1 keymap is required")
        }
    }

    func key(
        _ request: WaylandRequest<ZwpVirtualKeyboardV1Server>,
        time: UInt32,
        key: UInt32,
        state: UInt32
    ) {
        guard requireKeymap(request) else { return }
        switch state {
        case 0:
            pressedKeys.remove(key)
            dispatchKey(key, pressed: false, time: time)
        case 1:
            pressedKeys.insert(key)
            dispatchKey(key, pressed: true, time: time)
        default:
            request.postError(code: 0, message: "invalid virtual-keyboard key state")
        }
    }

    func modifiers(
        _ request: WaylandRequest<ZwpVirtualKeyboardV1Server>,
        mods_depressed: UInt32,
        mods_latched: UInt32,
        mods_locked: UInt32,
        group: UInt32
    ) {
        guard requireKeymap(request) else { return }
        host.inputHost?.dispatch.applySyntheticModifiers(
            depressed: mods_depressed,
            latched: mods_latched,
            locked: mods_locked,
            group: group)
    }

    func destroy(_ request: WaylandRequest<ZwpVirtualKeyboardV1Server>) {
        retire()
        unsafe wl_resource_destroy(request.resource)
    }

    private func requireKeymap(
        _ request: WaylandRequest<ZwpVirtualKeyboardV1Server>
    ) -> Bool {
        guard hasKeymap else {
            request.postError(.noKeymap, message: "keymap must precede keyboard events")
            return false
        }
        return true
    }

    private func dispatchKey(_ key: UInt32, pressed: Bool, time: UInt32) {
        guard let dispatch = host.inputHost?.dispatch else { return }
        var event = WireEventRecord(
            kind: pressed ? .keyDown : .keyUp,
            flags: dispatch.streamFlags,
            timestampNs: UInt64(time) * 1_000_000,
            x: dispatch.cursorX,
            y: dispatch.cursorY)
        event.data0 = UInt64(key)
        event.data2 = UInt64.max
        _ = dispatch.dispatch(event, location: .annotatedSession)
    }

    private func retire() {
        guard !retired else { return }
        retired = true
        let now = UInt32(truncatingIfNeeded: InputDispatch.monotonicNowNs() / 1_000_000)
        for key in pressedKeys.sorted() {
            dispatchKey(key, pressed: false, time: now)
        }
        pressedKeys.removeAll(keepingCapacity: false)
    }
}

@MainActor
@safe final class VirtualPointerManager: ZwlrVirtualPointerManagerV1Requests {
    private unowned let host: RouterHost
    private unowned let seat: WlSeat

    init(host: RouterHost, seat: WlSeat) {
        self.host = host
        self.seat = seat
    }

    func createVirtualPointer(
        _ request: WaylandRequest<ZwlrVirtualPointerManagerV1Server>,
        seat borrowedSeat: WaylandBorrowedObject<WlSeatServer>?,
        id: WlNewId<ZwlrVirtualPointerV1Server>
    ) {
        create(request, seat: borrowedSeat, output: nil, id: id)
    }

    func createVirtualPointerWithOutput(
        _ request: WaylandRequest<ZwlrVirtualPointerManagerV1Server>,
        seat borrowedSeat: WaylandBorrowedObject<WlSeatServer>?,
        output borrowedOutput: WaylandBorrowedObject<WlOutputServer>?,
        id: WlNewId<ZwlrVirtualPointerV1Server>
    ) {
        let output: WlOutput?
        if let borrowedOutput {
            guard borrowedOutput.clientID == id.clientID,
                let ownedOutput = borrowedOutput.output
            else { return }
            output = ownedOutput
        } else {
            output = nil
        }
        create(request, seat: borrowedSeat, output: output, id: id)
    }

    private func create(
        _ request: WaylandRequest<ZwlrVirtualPointerManagerV1Server>,
        seat borrowedSeat: WaylandBorrowedObject<WlSeatServer>?,
        output: WlOutput?,
        id: WlNewId<ZwlrVirtualPointerV1Server>
    ) {
        guard
            borrowedSeat == nil
                || (borrowedSeat?.clientID == id.clientID
                    && borrowedSeat?.owner(as: SeatBinding.self)?.seat === seat)
        else { return }
        _ = id.create(
            owner: { handle in
                VirtualPointer(resource: handle, host: self.host, output: output)
            })
    }
}

@MainActor
@safe final class VirtualPointer: ZwlrVirtualPointerV1Requests {
    private let resource: WaylandResourceHandle<ZwlrVirtualPointerV1Server>
    private unowned let host: RouterHost
    private weak var output: WlOutput?
    private var pressedButtons: Set<UInt32> = []
    private var currentAxisSource: UInt32 = 0
    private var retired = false

    init(
        resource: WaylandResourceHandle<ZwlrVirtualPointerV1Server>,
        host: RouterHost,
        output: WlOutput?
    ) {
        self.resource = resource
        self.host = host
        self.output = output
    }

    isolated deinit { retire() }

    func motion(
        _ request: WaylandRequest<ZwlrVirtualPointerV1Server>,
        time: UInt32,
        dx: Double,
        dy: Double
    ) {
        guard dx.isFinite, dy.isFinite, let dispatch = host.inputHost?.dispatch else { return }
        let snapshot = dispatch.currentSnapshot()
        var event = pointerRecord(
            kind: snapshot.dragKind,
            time: time,
            x: snapshot.cursorX + dx,
            y: snapshot.cursorY + dy,
            dispatch: dispatch)
        event.data0 = dx.bitPattern
        event.data1 = dy.bitPattern
        event.data2 = dx.bitPattern
        event.data3 = dy.bitPattern
        _ = dispatch.dispatch(event, location: .annotatedSession)
    }

    func motionAbsolute(
        _ request: WaylandRequest<ZwlrVirtualPointerV1Server>,
        time: UInt32,
        x: UInt32,
        y: UInt32,
        x_extent: UInt32,
        y_extent: UInt32
    ) {
        guard x_extent > 0, y_extent > 0,
            x <= x_extent, y <= y_extent,
            let dispatch = host.inputHost?.dispatch
        else { return }
        let bounds = absoluteBounds(dispatch: dispatch)
        let width = max(0, bounds.maxX - bounds.minX)
        let height = max(0, bounds.maxY - bounds.minY)
        let destinationX = bounds.minX + width * Double(x) / Double(x_extent)
        let destinationY = bounds.minY + height * Double(y) / Double(y_extent)
        let dx = destinationX - dispatch.cursorX
        let dy = destinationY - dispatch.cursorY
        var event = pointerRecord(
            kind: dispatch.currentSnapshot().dragKind,
            time: time,
            x: destinationX,
            y: destinationY,
            dispatch: dispatch)
        event.data0 = dx.bitPattern
        event.data1 = dy.bitPattern
        event.data2 = dx.bitPattern
        event.data3 = dy.bitPattern
        _ = dispatch.dispatch(event, location: .annotatedSession)
    }

    func button(
        _ request: WaylandRequest<ZwlrVirtualPointerV1Server>,
        time: UInt32,
        button: UInt32,
        state: WlPointerButtonState
    ) {
        let pressed: Bool
        switch state.rawValue {
        case 0:
            pressed = false
            pressedButtons.remove(button)
        case 1:
            pressed = true
            pressedButtons.insert(button)
        default:
            return
        }
        dispatchButton(button, pressed: pressed, time: time)
    }

    func axis(
        _ request: WaylandRequest<ZwlrVirtualPointerV1Server>,
        time: UInt32,
        axis: WlPointerAxis,
        value: Double
    ) {
        guard value.isFinite else { return }
        dispatchAxis(request, time: time, axis: axis, value: value, discrete: 0)
    }

    func axisDiscrete(
        _ request: WaylandRequest<ZwlrVirtualPointerV1Server>,
        time: UInt32,
        axis: WlPointerAxis,
        value: Double,
        discrete: Int32
    ) {
        guard value.isFinite else { return }
        dispatchAxis(
            request, time: time, axis: axis, value: value,
            discrete: discrete.multipliedReportingOverflow(by: 120).partialValue)
    }

    func axisStop(
        _ request: WaylandRequest<ZwlrVirtualPointerV1Server>,
        time: UInt32,
        axis: WlPointerAxis
    ) {
        dispatchAxis(request, time: time, axis: axis, value: 0, discrete: 0)
    }

    func axisSource(
        _ request: WaylandRequest<ZwlrVirtualPointerV1Server>,
        axis_source: WlPointerAxisSource
    ) {
        guard axis_source.rawValue <= 3 else {
            request.postError(.invalidAxisSource, message: "invalid virtual-pointer axis source")
            return
        }
        currentAxisSource = axis_source.rawValue
    }

    func frame(_ request: WaylandRequest<ZwlrVirtualPointerV1Server>) {
        host.inputHost?.dispatch.deliverPointerFrame()
    }

    func destroy(_ request: WaylandRequest<ZwlrVirtualPointerV1Server>) {
        retire()
        unsafe wl_resource_destroy(request.resource)
    }

    private func dispatchAxis(
        _ request: WaylandRequest<ZwlrVirtualPointerV1Server>,
        time: UInt32,
        axis: WlPointerAxis,
        value: Double,
        discrete: Int32
    ) {
        guard axis.rawValue <= 1 else {
            request.postError(.invalidAxis, message: "invalid virtual-pointer axis")
            return
        }
        guard let dispatch = host.inputHost?.dispatch else { return }
        var event = pointerRecord(
            kind: .scrollWheel,
            time: time,
            x: dispatch.cursorX,
            y: dispatch.cursorY,
            dispatch: dispatch)
        event.data0 = value.bitPattern
        event.data1 = UInt64(UInt32(bitPattern: discrete))
        event.data2 = UInt64(axis.rawValue)
        event.data3 = UInt64(currentAxisSource)
        _ = dispatch.dispatch(event, location: .annotatedSession)
    }

    private func dispatchButton(_ button: UInt32, pressed: Bool, time: UInt32) {
        guard let dispatch = host.inputHost?.dispatch else { return }
        let kind: WireEventKind
        switch button {
        case btnLeft: kind = pressed ? .leftMouseDown : .leftMouseUp
        case btnRight: kind = pressed ? .rightMouseDown : .rightMouseUp
        default: kind = pressed ? .otherMouseDown : .otherMouseUp
        }
        var event = pointerRecord(
            kind: kind,
            time: time,
            x: dispatch.cursorX,
            y: dispatch.cursorY,
            dispatch: dispatch)
        event.data0 = UInt64(button)
        event.data1 = 1
        _ = dispatch.dispatch(event, location: .annotatedSession)
    }

    private func pointerRecord(
        kind: WireEventKind,
        time: UInt32,
        x: Double,
        y: Double,
        dispatch: InputDispatch
    ) -> WireEventRecord {
        WireEventRecord(
            kind: kind,
            flags: dispatch.streamFlags,
            timestampNs: UInt64(time) * 1_000_000,
            x: x,
            y: y)
    }

    private func absoluteBounds(dispatch: InputDispatch) -> WirePointerBounds {
        guard let output else { return dispatch.pointerBounds() }
        let rect = output.logicalRect
        return WirePointerBounds(
            minX: Double(rect.x),
            minY: Double(rect.y),
            maxX: Double(rect.x + max(1, rect.width) - 1),
            maxY: Double(rect.y + max(1, rect.height) - 1))
    }

    private func retire() {
        guard !retired else { return }
        retired = true
        let now = UInt32(truncatingIfNeeded: InputDispatch.monotonicNowNs() / 1_000_000)
        for button in pressedButtons.sorted() {
            dispatchButton(button, pressed: false, time: now)
        }
        pressedButtons.removeAll(keepingCapacity: false)
    }
}
