import WaylandProtocolTypes
import WaylandServer
import WaylandServerDispatch

private struct InputMethodTextState: Equatable {
    var surroundingText: String?
    var cursor: UInt32?
    var anchor: UInt32?
    var changeCause: UInt32
    var contentHint: UInt32
    var contentPurpose: UInt32

    init(_ snapshot: TextInputServerSnapshot) {
        surroundingText = snapshot.surroundingText
        cursor = snapshot.cursorByteOffset.flatMap { $0 >= 0 ? UInt32($0) : nil }
        anchor = snapshot.anchorByteOffset.flatMap { $0 >= 0 ? UInt32($0) : nil }
        changeCause = snapshot.changeCause
        contentHint = snapshot.contentHint
        contentPurpose = snapshot.contentPurpose
    }
}

private struct PendingInputMethodState {
    var commit: String?
    var preedit: (text: String, cursorBegin: Int32, cursorEnd: Int32)?
    var deleteBefore: UInt32 = 0
    var deleteAfter: UInt32 = 0
}

extension TextInputSeat: ZwpInputMethodManagerV2Requests {
    func getInputMethod(
        _ request: WaylandRequest<ZwpInputMethodManagerV2Server>,
        seat seatResource: WaylandBorrowedObject<WlSeatServer>,
        input_method id: WlNewId<ZwpInputMethodV2Server>
    ) {
        guard let binding = seatResource.owner(as: SeatBinding.self),
            binding.seat === seat,
            seatResource.clientID == id.clientID
        else { return }

        let isAvailable = inputMethod == nil
        _ = id.create(
            owner: { handle in
                InputMethodV2(
                    resource: handle,
                    textInputSeat: self,
                    isAvailable: isAvailable)
            },
            installed: { inputMethod in
                if isAvailable {
                    self.inputMethod = inputMethod
                    if let snapshot = self.latestSnapshot {
                        inputMethod.apply(snapshot: snapshot)
                    }
                } else {
                    inputMethod.sendUnavailable()
                }
            })
    }

    func refreshInputMethodKeymap() {
        inputMethod?.keyboardGrab?.sendKeymap()
    }

    func refreshInputMethodRepeatInfo() {
        inputMethod?.keyboardGrab?.sendRepeatInfo()
    }

    func sendInputMethodKey(
        timeMsec: UInt32,
        keycode: UInt32,
        keyState: UInt32
    ) -> Bool {
        inputMethod?.keyboardGrab?.sendKey(
            timeMsec: timeMsec,
            keycode: keycode,
            keyState: keyState) ?? false
    }

    func sendInputMethodModifiers(
        depressed: UInt32,
        latched: UInt32,
        locked: UInt32,
        group: UInt32
    ) -> Bool {
        inputMethod?.keyboardGrab?.sendModifiers(
            depressed: depressed,
            latched: latched,
            locked: locked,
            group: group) ?? false
    }
}

@MainActor
@safe final class InputMethodV2: ZwpInputMethodV2Requests {
    private let resource: WaylandResourceHandle<ZwpInputMethodV2Server>
    private weak var textInputSeat: TextInputSeat?
    private let isAvailable: Bool
    private var isActive = false
    private var doneCount: UInt32 = 0
    private var textState: InputMethodTextState?
    private var cursorRectangle: TextInputServerRectangle?
    private var pending = PendingInputMethodState()
    private var popupSurfaces = WeakObjectList<InputPopupSurfaceV2>()
    private(set) weak var keyboardGrab: InputMethodKeyboardGrabV2?

    init(
        resource: WaylandResourceHandle<ZwpInputMethodV2Server>,
        textInputSeat: TextInputSeat,
        isAvailable: Bool
    ) {
        self.resource = resource
        self.textInputSeat = textInputSeat
        self.isAvailable = isAvailable
    }

    isolated deinit {
        popupSurfaces.forEach { $0.destroy() }
        keyboardGrab?.destroy()
        if textInputSeat?.inputMethod === self {
            textInputSeat?.inputMethod = nil
        }
    }

    func sendUnavailable() {
        _ = resource.sendUnavailable()
    }

    func apply(snapshot: TextInputServerSnapshot?) {
        guard isAvailable else { return }
        guard let snapshot, snapshot.enabled else {
            guard isActive else { return }
            isActive = false
            textState = nil
            cursorRectangle = nil
            pending = PendingInputMethodState()
            _ = resource.sendDeactivate()
            sendDone()
            return
        }

        let nextState = InputMethodTextState(snapshot)
        let activating = !isActive
        let stateChanged = nextState != textState
        isActive = true
        cursorRectangle = snapshot.cursorRectangle
        if activating {
            pending = PendingInputMethodState()
            _ = resource.sendActivate()
        }
        if activating || stateChanged {
            sendState(nextState)
            textState = nextState
            sendDone()
        }
        sendPopupRectangle()
    }

    func commitString(
        _ request: WaylandRequest<ZwpInputMethodV2Server>,
        text: String
    ) {
        guard isAvailable, text.utf8.count <= 4_000 else { return }
        pending.commit = text
    }

    func setPreeditString(
        _ request: WaylandRequest<ZwpInputMethodV2Server>,
        text: String,
        cursor_begin: Int32,
        cursor_end: Int32
    ) {
        guard isAvailable, text.utf8.count <= 4_000,
            Self.isValidPreeditOffset(cursor_begin, in: text),
            Self.isValidPreeditOffset(cursor_end, in: text)
        else { return }
        pending.preedit = (text, cursor_begin, cursor_end)
    }

    func deleteSurroundingText(
        _ request: WaylandRequest<ZwpInputMethodV2Server>,
        before_length: UInt32,
        after_length: UInt32
    ) {
        guard isAvailable else { return }
        pending.deleteBefore = before_length
        pending.deleteAfter = after_length
    }

    func commit(
        _ request: WaylandRequest<ZwpInputMethodV2Server>,
        serial: UInt32
    ) {
        let committed = pending
        pending = PendingInputMethodState()
        guard isAvailable, isActive, serial == doneCount else { return }
        _ = textInputSeat?.send(
            TextInputServerEventBatch(
                preedit: committed.preedit.map {
                    ($0.text, $0.cursorBegin, $0.cursorEnd)
                },
                commit: committed.commit,
                deleteBefore: committed.deleteBefore,
                deleteAfter: committed.deleteAfter))
    }

    func getInputPopupSurface(
        _ request: WaylandRequest<ZwpInputMethodV2Server>,
        id: WlNewId<ZwpInputPopupSurfaceV2Server>,
        surface surfaceResource: WaylandBorrowedObject<WlSurfaceServer>
    ) {
        guard isAvailable,
            surfaceResource.clientID == id.clientID,
            let surface = surfaceResource.owner(as: WlSurface.self)
        else { return }
        guard !surface.hasRole else {
            request.postError(.role, message: "input popup surface already has a role")
            return
        }
        _ = id.create(
            owner: { handle in
                InputPopupSurfaceV2(
                    resource: handle,
                    inputMethod: self,
                    surface: surface)
            },
            installed: { popup in
                precondition(surface.assignRole(popup))
                self.popupSurfaces.append(popup)
                if self.isActive, let rectangle = self.cursorRectangle {
                    popup.send(rectangle)
                }
            })
    }

    func grabKeyboard(
        _ request: WaylandRequest<ZwpInputMethodV2Server>,
        keyboard id: WlNewId<ZwpInputMethodKeyboardGrabV2Server>
    ) {
        guard isAvailable else { return }
        keyboardGrab?.destroy()
        _ = id.create(
            owner: { handle in
                InputMethodKeyboardGrabV2(
                    resource: handle,
                    inputMethod: self,
                    seat: textInputSeat?.seat)
            },
            installed: { grab in
                self.keyboardGrab = grab
                grab.sendKeymap()
                grab.sendRepeatInfo()
            })
    }

    func destroy(_ request: WaylandRequest<ZwpInputMethodV2Server>) {
        request.destroy()
    }

    private func sendState(_ state: InputMethodTextState) {
        if let text = state.surroundingText,
            let cursor = state.cursor,
            let anchor = state.anchor
        {
            _ = resource.sendSurroundingText(
                text: text, cursor: cursor, anchor: anchor)
        }
        _ = resource.sendTextChangeCause(
            cause: ZwpTextInputV3ChangeCause(rawValue: state.changeCause))
        _ = resource.sendContentType(
            hint: ZwpTextInputV3ContentHint(rawValue: state.contentHint),
            purpose: ZwpTextInputV3ContentPurpose(rawValue: state.contentPurpose))
    }

    private func sendDone() {
        guard resource.sendDone() else { return }
        doneCount &+= 1
    }

    private func sendPopupRectangle() {
        guard isActive, let cursorRectangle else { return }
        popupSurfaces.forEach { $0.send(cursorRectangle) }
    }

    private static func isValidPreeditOffset(
        _ offset: Int32,
        in text: String
    ) -> Bool {
        if offset == -1 { return true }
        guard offset >= 0, Int(offset) <= text.utf8.count else { return false }
        let index = text.utf8.index(text.utf8.startIndex, offsetBy: Int(offset))
        return index.samePosition(in: text.unicodeScalars) != nil
    }
}

@MainActor
@safe
final class InputMethodKeyboardGrabV2:
    ZwpInputMethodKeyboardGrabV2Requests
{
    private let resource: WaylandResourceHandle<ZwpInputMethodKeyboardGrabV2Server>
    private weak var inputMethod: InputMethodV2?
    private weak var seat: WlSeat?

    init(
        resource: WaylandResourceHandle<ZwpInputMethodKeyboardGrabV2Server>,
        inputMethod: InputMethodV2,
        seat: WlSeat?
    ) {
        self.resource = resource
        self.inputMethod = inputMethod
        self.seat = seat
    }

    func sendKeymap() {
        seat?.sendInputMethodKeymap(to: resource)
    }

    func sendRepeatInfo() {
        guard let repeatInfo = seat?.inputMethodRepeatInfo else { return }
        _ = resource.sendRepeatInfo(rate: repeatInfo.rate, delay: repeatInfo.delay)
    }

    func sendKey(timeMsec: UInt32, keycode: UInt32, keyState: UInt32) -> Bool {
        guard let seat else { return false }
        return resource.sendKey(
            serial: seat.nextInputMethodSerial(),
            time: timeMsec,
            key: keycode,
            state: WlKeyboardKeyState(rawValue: keyState))
    }

    func sendModifiers(
        depressed: UInt32,
        latched: UInt32,
        locked: UInt32,
        group: UInt32
    ) -> Bool {
        guard let seat else { return false }
        return resource.sendModifiers(
            serial: seat.nextInputMethodSerial(),
            mods_depressed: depressed,
            mods_latched: latched,
            mods_locked: locked,
            group: group)
    }

    func release(
        _ request: WaylandRequest<ZwpInputMethodKeyboardGrabV2Server>
    ) {
        request.destroy()
    }

    func destroy() {
        resource.destroy()
    }
}

@MainActor
@safe
final class InputPopupSurfaceV2: ZwpInputPopupSurfaceV2Requests,
    WlSurfaceRole
{
    private let resource: WaylandResourceHandle<ZwpInputPopupSurfaceV2Server>
    private weak var inputMethod: InputMethodV2?
    private weak var surface: WlSurface?

    init(
        resource: WaylandResourceHandle<ZwpInputPopupSurfaceV2Server>,
        inputMethod: InputMethodV2,
        surface: WlSurface
    ) {
        self.resource = resource
        self.inputMethod = inputMethod
        self.surface = surface
    }

    func send(_ rectangle: TextInputServerRectangle) {
        _ = resource.sendTextInputRectangle(
            x: rectangle.x,
            y: rectangle.y,
            width: rectangle.width,
            height: rectangle.height)
    }

    func destroy(_ request: WaylandRequest<ZwpInputPopupSurfaceV2Server>) {
        request.destroy()
    }

    func destroy() {
        resource.destroy()
    }

    func roleSurfaceCommit(_ surface: WlSurface, isInitial: Bool) {}

    func roleSurfaceDestroyed(_ surface: WlSurface) {
        self.surface = nil
    }
}
