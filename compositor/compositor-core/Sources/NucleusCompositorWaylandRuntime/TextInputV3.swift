import WaylandServerC
import WaylandServer
import WaylandServerDispatch

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

private final class WeakTextInputV3 {
    weak var value: TextInputV3?
    init(_ value: TextInputV3) { self.value = value }
}

/// The compositor-side owner for one seat's text-input-v3 objects.
///
/// Focus follows `WlSeat` keyboard focus. Each resource owns its own commit
/// counter and double-buffered client state; the manager arbitrates the single
/// enabled object and provides the input-method event projection.
final class TextInputManagerV3 {
    private unowned let seat: WlSeat
    private var inputs: [WeakTextInputV3] = []
    private weak var enabledInput: TextInputV3?
    private weak var focusedSurface: WlSurface?
    private(set) var snapshots: [TextInputServerSnapshot] = []

    init(seat: WlSeat) {
        self.seat = seat
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zwp_text_input_manager_v3(),
            version: 2,
            impl: self,
            bind: Self.bind)
    }

    var liveResourceCount: Int {
        compactInputs()
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
        compactInputs()
        guard let client = surface.resource.flatMap(wl_resource_get_client)
        else { return }
        let key = WlSeat.clientKey(client)
        for input in inputs.compactMap(\.value)
        where input.clientKey == key {
            input.focusEntered(surface)
        }
    }

    func keyboardLeave(_ surface: WlSurface) {
        guard focusedSurface === surface else { return }
        compactInputs()
        for input in inputs.compactMap(\.value)
        where input.focusedSurface === surface {
            input.focusLeft(surface)
        }
        focusedSurface = nil
    }

    func focusedSurfaceDestroyed(surfaceID: UInt32) {
        guard focusedSurface?.objectId == surfaceID else { return }
        compactInputs()
        for input in inputs.compactMap(\.value)
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
        compactInputs()
        inputs.append(WeakTextInputV3(input))
        guard let focusedSurface,
              focusedSurface.resource
                .flatMap(wl_resource_get_client)
                .map(WlSeat.clientKey) == input.clientKey
        else { return }
        input.focusEntered(focusedSurface)
    }

    fileprivate func unregister(_ input: TextInputV3) {
        if enabledInput === input {
            enabledInput = nil
        }
        inputs.removeAll {
            $0.value == nil || $0.value === input
        }
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

    private func compactInputs() {
        inputs.removeAll { $0.value == nil }
    }

    private static let bind: @convention(c) (
        OpaquePointer?,
        UnsafeMutableRawPointer?,
        UInt32,
        UInt32
    ) -> Void = { client, data, version, id in
        guard let client,
              let manager = NucleusWaylandRouter.impl(
                data,
                as: TextInputManagerV3.self)
        else { return }
        _ = WaylandResource.create(
            client: client,
            interface: swift_wayland_iface_zwp_text_input_manager_v3(),
            version: Int32(version),
            id: id,
            vtable: ZwpTextInputManagerV3Server.vtable,
            owner: manager)
    }
}

extension TextInputManagerV3: ZwpTextInputManagerV3Requests {
    func getTextInput(
        _ resource: UnsafeMutablePointer<wl_resource>,
        id: WlNewId,
        seat seatResource: UnsafeMutablePointer<wl_resource>?
    ) {
        guard let seatResource,
              let binding = WaylandResource.owner(
                of: seatResource,
                as: SeatBinding.self),
              binding.seat === seat,
              wl_resource_get_client(seatResource) == id.client
        else {
            swift_wayland_resource_post_error(
                resource,
                0,
                "text-input seat must belong to the requesting client")
            return
        }
        let input = TextInputV3(
            manager: self,
            clientKey: WlSeat.clientKey(id.client),
            version: id.version)
        guard let inputResource = id.create(
            vtable: ZwpTextInputV3Server.vtable,
            owner: input)
        else { return }
        input.bind(inputResource)
        register(input)
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
private final class TextInputV3: ZwpTextInputV3Requests,
    WlSurfaceCommitObserver
{
    private weak var manager: TextInputManagerV3?
    fileprivate let clientKey: UInt
    private let version: Int32
    private var resource: UnsafeMutablePointer<wl_resource>?
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
        manager: TextInputManagerV3,
        clientKey: UInt,
        version: Int32
    ) {
        self.manager = manager
        self.clientKey = clientKey
        self.version = version
    }

    deinit {
        if let focusedSurface {
            focusedSurface.removeCommitObserver(self)
        }
        manager?.unregister(self)
    }

    fileprivate func bind(
        _ resource: UnsafeMutablePointer<wl_resource>
    ) {
        self.resource = resource
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
        guard let resource, let surfaceResource = surface.resource else {
            return
        }
        ZwpTextInputV3Server.sendEnter(
            resource,
            surface: surfaceResource)
        recordSnapshot()
    }

    fileprivate func focusLeft(_ surface: WlSurface) {
        guard focusedSurface === surface else { return }
        if let resource, let surfaceResource = surface.resource {
            ZwpTextInputV3Server.sendLeave(
                resource,
                surface: surfaceResource)
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

    func enable(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard focusedSurface != nil else { return }
        pending.reset(forEnableCommand: true)
    }

    func disable(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard focusedSurface != nil else { return }
        pending.reset(forEnableCommand: false)
    }

    func setSurroundingText(
        _ resource: UnsafeMutablePointer<wl_resource>,
        text: UnsafePointer<CChar>?,
        cursor: Int32,
        anchor: Int32
    ) {
        guard focusedSurface != nil, let text else { return }
        let value = String(cString: text)
        guard value.utf8.count <= 4_000,
              Self.isValidUTF8Boundary(cursor, in: value),
              Self.isValidUTF8Boundary(anchor, in: value)
        else { return }
        pending.surrounding = (value, cursor, anchor)
    }

    func setTextChangeCause(
        _ resource: UnsafeMutablePointer<wl_resource>,
        cause: UInt32
    ) {
        guard focusedSurface != nil, cause <= 1 else { return }
        pending.changeCause = cause
    }

    func setContentType(
        _ resource: UnsafeMutablePointer<wl_resource>,
        hint: UInt32,
        purpose: UInt32
    ) {
        guard focusedSurface != nil, purpose <= 13 else { return }
        let allowedHints: UInt32 = version >= 2 ? 0x1fff : 0x03ff
        guard hint & ~allowedHints == 0 else { return }
        pending.contentType = (hint, purpose)
    }

    func setCursorRectangle(
        _ resource: UnsafeMutablePointer<wl_resource>,
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

    func commit(_ resource: UnsafeMutablePointer<wl_resource>) {
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
        _ resource: UnsafeMutablePointer<wl_resource>,
        available_actions: UnsafeMutablePointer<wl_array>?
    ) {
        guard version >= 2, let available_actions else { return }
        let count = Int(available_actions.pointee.size)
            / MemoryLayout<UInt32>.stride
        guard count > 0, let data = available_actions.pointee.data else {
            return
        }
        let actions = data.bindMemory(
            to: UInt32.self,
            capacity: count)
        var seen: Set<UInt32> = []
        for index in 0..<count {
            let action = actions[index]
            guard action <= 1, seen.insert(action).inserted else {
                swift_wayland_resource_post_error(
                    resource,
                    UInt32(
                        ZWP_TEXT_INPUT_V3_ERROR_INVALID_ACTION.rawValue),
                    "text-input action is invalid or duplicated")
                return
            }
        }
    }

    func showInputPanel(
        _ resource: UnsafeMutablePointer<wl_resource>
    ) {}

    func hideInputPanel(
        _ resource: UnsafeMutablePointer<wl_resource>
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
        guard let resource, enabled, focusedSurface != nil else {
            return
        }
        if version >= 2 {
            for hint in batch.preeditHints {
                ZwpTextInputV3Server.sendPreeditHint(
                    resource,
                    start: hint.start,
                    end: hint.end,
                    hint: hint.hint)
            }
            if let language = batch.language {
                language.withCString {
                    ZwpTextInputV3Server.sendLanguage(
                        resource,
                        language: $0)
                }
            }
        }
        if batch.deleteBefore > 0 || batch.deleteAfter > 0 {
            ZwpTextInputV3Server.sendDeleteSurroundingText(
                resource,
                before_length: batch.deleteBefore,
                after_length: batch.deleteAfter)
        }
        if let commit = batch.commit {
            commit.withCString {
                ZwpTextInputV3Server.sendCommitString(
                    resource,
                    text: $0)
            }
        }
        if let preedit = batch.preedit {
            if let text = preedit.text {
                text.withCString {
                    ZwpTextInputV3Server.sendPreeditString(
                        resource,
                        text: $0,
                        cursor_begin: preedit.cursorBegin,
                        cursor_end: preedit.cursorEnd)
                }
            } else {
                ZwpTextInputV3Server.sendPreeditString(
                    resource,
                    text: nil,
                    cursor_begin: preedit.cursorBegin,
                    cursor_end: preedit.cursorEnd)
            }
        }
        if version >= 2, let action = batch.action {
            ZwpTextInputV3Server.sendAction(
                resource,
                action: action,
                serial: commitCount)
        }
        ZwpTextInputV3Server.sendDone(
            resource,
            serial: batch.doneSerial ?? commitCount)
    }

    private func recordSnapshot() {
        manager?.record(TextInputServerSnapshot(
            resourceID: resource.map { wl_resource_get_id($0) } ?? 0,
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
