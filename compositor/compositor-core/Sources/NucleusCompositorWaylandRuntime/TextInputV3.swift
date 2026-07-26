import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes

struct TextInputServerRectangle: Sendable, Equatable {
    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32
}

struct TextInputServerSnapshot: Sendable, Equatable {
    var resourceID: UInt32
    var focusedSurfaceID: UInt32?
    var enabled: Bool
    var surroundingText: String?
    var cursorByteOffset: Int32?
    var anchorByteOffset: Int32?
    var changeCause: UInt32
    var contentHint: UInt32
    var contentPurpose: UInt32
    var cursorRectangle: TextInputServerRectangle?
    var commitCount: UInt32
}

struct TextInputServerEventBatch: Sendable {
    var preedit: (
        text: String?,
        cursorBegin: Int32,
        cursorEnd: Int32
    )?
    var commit: String?
    var deleteBefore: UInt32
    var deleteAfter: UInt32
    var preeditHints: [(
        start: UInt32,
        end: UInt32,
        hint: UInt32
    )]
    var language: String?
    var action: UInt32?
    var doneSerial: UInt32?

    init(
        preedit: (
            text: String?,
            cursorBegin: Int32,
            cursorEnd: Int32
        )? = nil,
        commit: String? = nil,
        deleteBefore: UInt32 = 0,
        deleteAfter: UInt32 = 0,
        preeditHints: [(
            start: UInt32,
            end: UInt32,
            hint: UInt32
        )] = [],
        language: String? = nil,
        action: UInt32? = nil,
        doneSerial: UInt32? = nil
    ) {
        self.preedit = preedit
        self.commit = commit
        self.deleteBefore = deleteBefore
        self.deleteAfter = deleteAfter
        self.preeditHints = preeditHints
        self.language = language
        self.action = action
        self.doneSerial = doneSerial
    }
}

/// The compositor-side owner for one seat's text-input-v3 objects.
///
/// Focus follows `WlSeat` keyboard focus. Each resource owns its own commit
/// counter and double-buffered client state; the manager arbitrates the single
/// enabled object and provides the input-method event projection.
@MainActor
@safe final class TextInputManagerV3 {
    private unowned let seat: WlSeat
    private var inputs = WeakObjectList<TextInputV3>()
    private weak var enabledInput: TextInputV3?
    private weak var focusedSurface: WlSurface?
    private(set) var snapshots: [TextInputServerSnapshot] = []

    init(seat: WlSeat) {
        self.seat = seat
    }

    var liveResourceCount: Int {
        return inputs.count
    }

    var latestSnapshot: TextInputServerSnapshot? {
        snapshots.last
    }

    func keyboardEnter(_ surface: WlSurface) {
        if focusedSurface === surface { return }
        if let previous = focusedSurface {
            keyboardLeave(previous)
        }
        focusedSurface = surface
        guard let key = surface.protocolResource?.clientID else { return }
        for input in inputs.liveValues()
        where input.clientKey == key {
            input.focusEntered(surface)
        }
    }

    func keyboardLeave(_ surface: WlSurface) {
        guard focusedSurface === surface else { return }
        for input in inputs.liveValues()
        where input.focusedSurface === surface {
            input.focusLeft(surface)
        }
        focusedSurface = nil
    }

    func focusedSurfaceDestroyed(surfaceID: UInt32) {
        guard focusedSurface?.objectId == surfaceID else { return }
        for input in inputs.liveValues()
        where input.focusedSurface?.objectId == surfaceID {
            input.focusWasDestroyed()
        }
        focusedSurface = nil
    }

    @discardableResult
    func send(_ batch: TextInputServerEventBatch) -> Bool {
        guard let input = enabledInput,
              input.enabled,
              input.focusedSurface === focusedSurface
        else { return false }
        input.send(batch)
        return true
    }

    fileprivate func register(_ input: TextInputV3) {
        inputs.append(input)
        guard let focusedSurface,
              focusedSurface.protocolResource?.clientID == input.clientKey
        else { return }
        input.focusEntered(focusedSurface)
    }

    fileprivate func unregister(_ input: TextInputV3) {
        if enabledInput === input {
            enabledInput = nil
        }
        inputs.remove(input)
    }

    fileprivate func enable(_ input: TextInputV3) -> Bool {
        guard enabledInput == nil || enabledInput === input else {
            return false
        }
        enabledInput = input
        return true
    }

    fileprivate func disable(_ input: TextInputV3) {
        if enabledInput === input {
            enabledInput = nil
        }
    }

    fileprivate func record(_ snapshot: TextInputServerSnapshot) {
        snapshots.append(snapshot)
    }

}

extension TextInputManagerV3: ZwpTextInputManagerV3Requests {
    func getTextInput(
        _ request: WaylandRequest<ZwpTextInputManagerV3Server>,
        id: WlNewId<ZwpTextInputV3Server>,
        seat seatResource: WaylandBorrowedObject<WlSeatServer>
    ) {
        guard let binding = seatResource.owner(as: SeatBinding.self),
              binding.seat === seat,
              seatResource.clientID == id.clientID
        else { return }
        _ = id.create(
            owner: { handle in
                TextInputV3(
                    resource: handle,
                    manager: self,
                    clientKey: id.clientID,
                    version: id.version)
            },
            installed: { input in
                self.register(input)
            })
    }
}

private struct PendingTextInputState {
    var enableCommand: Bool?
    var surrounding:
        (text: String, cursor: Int32, anchor: Int32)?
    var changeCause: UInt32?
    var contentType: (hint: UInt32, purpose: UInt32)?
    var cursorRectangle: TextInputServerRectangle?

    mutating func reset(forEnableCommand enabled: Bool) {
        self = PendingTextInputState(enableCommand: enabled)
    }

    mutating func clearAfterCommit() {
        enableCommand = nil
        surrounding = nil
        changeCause = nil
        contentType = nil
        cursorRectangle = nil
    }
}

/// One resource-owned text input. No platform editor or surface retains it.
@MainActor
@safe private final class TextInputV3: ZwpTextInputV3Requests,
    WlSurfaceCommitObserver
{
    private weak var manager: TextInputManagerV3?
    fileprivate let clientKey: WaylandClientID
    private let version: Int32
    private let resource: WaylandResourceHandle<ZwpTextInputV3Server>
    fileprivate weak var focusedSurface: WlSurface?
    fileprivate private(set) var enabled = false
    private var pending = PendingTextInputState()
    private var surrounding:
        (text: String, cursor: Int32, anchor: Int32)?
    private var changeCause: UInt32 = 0
    private var contentHint: UInt32 = 0
    private var contentPurpose: UInt32 = 0
    private var committedCursorRectangle: TextInputServerRectangle?
    private var appliedCursorRectangle: TextInputServerRectangle?
    private var commitCount: UInt32 = 0

    init(
        resource: WaylandResourceHandle<ZwpTextInputV3Server>,
        manager: TextInputManagerV3,
        clientKey: WaylandClientID,
        version: Int32
    ) {
        self.resource = resource
        self.manager = manager
        self.clientKey = clientKey
        self.version = version
    }

    isolated deinit {
        if let focusedSurface {
            focusedSurface.removeCommitObserver(self)
        }
        manager?.unregister(self)
    }

    fileprivate func focusEntered(_ surface: WlSurface) {
        if focusedSurface === surface { return }
        if let focusedSurface {
            focusedSurface.removeCommitObserver(self)
        }
        manager?.disable(self)
        enabled = false
        resetCurrentState()
        pending = PendingTextInputState()
        focusedSurface = surface
        surface.addCommitObserver(self)
        guard let surfaceResource = surface.protocolResource else { return }
        resource.sendEnter(surface: surfaceResource)
        recordSnapshot()
    }

    fileprivate func focusLeft(_ surface: WlSurface) {
        guard focusedSurface === surface else { return }
        if let surfaceResource = surface.protocolResource {
            resource.sendLeave(surface: surfaceResource)
        }
        detachFromFocusedSurface()
    }

    fileprivate func focusWasDestroyed() {
        detachFromFocusedSurface()
    }

    private func detachFromFocusedSurface() {
        focusedSurface?.removeCommitObserver(self)
        focusedSurface = nil
        manager?.disable(self)
        enabled = false
        resetCurrentState()
        pending = PendingTextInputState()
        recordSnapshot()
    }

    private func resetCurrentState() {
        surrounding = nil
        changeCause = 0
        contentHint = 0
        contentPurpose = 0
        committedCursorRectangle = nil
        appliedCursorRectangle = nil
    }

    func enable(_ request: WaylandRequest<ZwpTextInputV3Server>) {
        guard focusedSurface != nil else { return }
        pending.reset(forEnableCommand: true)
    }

    func disable(_ request: WaylandRequest<ZwpTextInputV3Server>) {
        guard focusedSurface != nil else { return }
        pending.reset(forEnableCommand: false)
    }

    func setSurroundingText(
        _ request: WaylandRequest<ZwpTextInputV3Server>,
        text: String,
        cursor: Int32,
        anchor: Int32
    ) {
        guard focusedSurface != nil else { return }
        guard text.utf8.count <= 4_000,
              Self.isValidUTF8Boundary(cursor, in: text),
              Self.isValidUTF8Boundary(anchor, in: text)
        else { return }
        pending.surrounding = (text, cursor, anchor)
    }

    func setTextChangeCause(
        _ request: WaylandRequest<ZwpTextInputV3Server>,
        cause: ZwpTextInputV3ChangeCause
    ) {
        guard focusedSurface != nil, cause.rawValue <= 1 else { return }
        pending.changeCause = cause.rawValue
    }

    func setContentType(
        _ request: WaylandRequest<ZwpTextInputV3Server>,
        hint: ZwpTextInputV3ContentHint,
        purpose: ZwpTextInputV3ContentPurpose
    ) {
        guard focusedSurface != nil, purpose.rawValue <= 13 else { return }
        let allowedHints: UInt32 = version >= 2 ? 0x1fff : 0x03ff
        guard hint.rawValue & ~allowedHints == 0 else { return }
        pending.contentType = (hint.rawValue, purpose.rawValue)
    }

    func setCursorRectangle(
        _ request: WaylandRequest<ZwpTextInputV3Server>,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32
    ) {
        guard focusedSurface != nil, width >= 0, height >= 0 else {
            return
        }
        pending.cursorRectangle = TextInputServerRectangle(
            x: x,
            y: y,
            width: width,
            height: height)
    }

    func commit(_ request: WaylandRequest<ZwpTextInputV3Server>) {
        commitCount &+= 1
        guard focusedSurface != nil else {
            pending = PendingTextInputState()
            recordSnapshot()
            return
        }

        if let enableCommand = pending.enableCommand {
            resetCurrentState()
            if enableCommand, manager?.enable(self) == true {
                enabled = true
            } else {
                manager?.disable(self)
                enabled = false
            }
        }
        if enabled {
            if let value = pending.surrounding {
                surrounding = value
            }
            if let value = pending.changeCause {
                changeCause = value
            }
            if let value = pending.contentType {
                contentHint = value.hint
                contentPurpose = value.purpose
            }
            if let value = pending.cursorRectangle {
                committedCursorRectangle = value
                if version < 2 {
                    appliedCursorRectangle = value
                }
            }
        }
        pending.clearAfterCommit()
        recordSnapshot()
        changeCause = 0
    }

    func setAvailableActions(
        _ request: WaylandRequest<ZwpTextInputV3Server>,
        available_actions: WaylandArrayView
    ) {
        guard version >= 2,
              let actions = available_actions.copiedElements(of: UInt32.self),
              !actions.isEmpty
        else { return }
        var seen: Set<UInt32> = []
        for action in actions {
            guard action <= 1, seen.insert(action).inserted else {
                request.postError(
                    .invalidAction,
                    message: "text-input action is invalid or duplicated")
                return
            }
        }
    }

    func showInputPanel(
        _ request: WaylandRequest<ZwpTextInputV3Server>
    ) {}

    func hideInputPanel(
        _ request: WaylandRequest<ZwpTextInputV3Server>
    ) {}

    func captureSurfaceCommit(
        _ surface: WlSurface,
        bufferAttached: Bool,
        attachedBufferIsNonNull: Bool,
        attachedBufferSupportsExplicitSync: Bool,
        aux: inout SurfaceAuxState,
        effects: inout [() -> Void]
    ) -> Bool {
        guard version >= 2,
              focusedSurface === surface,
              enabled
        else { return true }
        if appliedCursorRectangle != committedCursorRectangle {
            appliedCursorRectangle = committedCursorRectangle
            recordSnapshot()
        }
        return true
    }

    fileprivate func send(_ batch: TextInputServerEventBatch) {
        guard enabled,
              focusedSurface != nil else {
            return
        }
        if resource.supportsPreeditHint {
            for hint in batch.preeditHints {
                resource.sendPreeditHint(
                    start: hint.start,
                    end: hint.end,
                    hint: ZwpTextInputV3PreeditHint(rawValue: hint.hint))
            }
        }
        if resource.supportsLanguage, let language = batch.language {
            resource.sendLanguage(language: language)
        }
        if batch.deleteBefore > 0 || batch.deleteAfter > 0 {
            resource.sendDeleteSurroundingText(
                before_length: batch.deleteBefore,
                after_length: batch.deleteAfter)
        }
        if let commit = batch.commit {
            resource.sendCommitString(text: commit)
        }
        if let preedit = batch.preedit {
            resource.sendPreeditString(
                text: preedit.text,
                cursor_begin: preedit.cursorBegin,
                cursor_end: preedit.cursorEnd)
        }
        if resource.supportsAction, let action = batch.action {
            resource.sendAction(
                action: ZwpTextInputV3Action(rawValue: action),
                serial: commitCount)
        }
        resource.sendDone(
            serial: batch.doneSerial ?? commitCount)
    }

    private func recordSnapshot() {
        manager?.record(TextInputServerSnapshot(
            resourceID: resource.objectID ?? 0,
            focusedSurfaceID: focusedSurface?.objectId,
            enabled: enabled,
            surroundingText: surrounding?.text,
            cursorByteOffset: surrounding?.cursor,
            anchorByteOffset: surrounding?.anchor,
            changeCause: changeCause,
            contentHint: contentHint,
            contentPurpose: contentPurpose,
            cursorRectangle: appliedCursorRectangle,
            commitCount: commitCount))
    }

    private static func isValidUTF8Boundary(
        _ offset: Int32,
        in text: String
    ) -> Bool {
        guard offset >= 0, Int(offset) <= text.utf8.count else {
            return false
        }
        let index = text.utf8.index(
            text.utf8.startIndex,
            offsetBy: Int(offset))
        return index.samePosition(in: text.unicodeScalars) != nil
    }
}
