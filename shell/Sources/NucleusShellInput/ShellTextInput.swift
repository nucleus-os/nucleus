import WaylandClientC
import WaylandClientDispatch
public import NucleusShellWayland
public import NucleusUI

/// The shell's `zwp_text_input_v3` client, wired to NucleusUI's input-method seam.
///
/// Implements `TextInputAdapter`, so a focused `TextField` drives the protocol
/// without knowing it exists, and the protocol's preedit/commit events drive the
/// field through `TextInputClient` — the same API a keystroke uses. There is no
/// second editing path for composed text.
///
/// The protocol is double-buffered: `enable`, `set_surrounding_text`,
/// `set_content_type`, and `set_cursor_rectangle` all stage state that only
/// takes effect on `commit`, and every commit increments a serial the compositor
/// echoes back in `done`. Incoming edits are always applied; only outbound
/// client state is deferred when the serial does not match the commit count.
@MainActor
@safe public final class ShellTextInput: TextInputAdapter {
    // The Wayland proxy is owned by this object from successful construction
    // through `close()`. All access stays on the main actor, the generated
    // listener borrows `listener`, and the proxy is destroyed before that
    // listener owner is released.
    private var textInput: OpaquePointer?
    /// The surface this text input is scoped to, set from `enter`.
    private var focusedSurface: UInt = 0

    /// Number of commit requests issued on this object.
    private var committedStateSerial: UInt32 = 0
    private var sessionGeneration: UInt64 = 0
    private var validDoneSerials: Set<UInt32> = []

    /// Preedit and commit arrive before `done` and apply on it — the protocol
    /// batches a composition update across several events.
    private var pendingPreedit: (text: String, cursorBegin: Int32, cursorEnd: Int32)?
    private var pendingCommitString: String?
    private var pendingDeleteBefore: UInt32 = 0
    private var pendingDeleteAfter: UInt32 = 0
    private var pendingPreeditHints: [
        (start: UInt32, end: UInt32, hint: UInt32)
    ] = []
    private var pendingAction: UInt32?
    private var pendingLanguage: String?
    private var pendingLanguageWasSet = false
    private var isApplyingDone = false

    private weak var activeClient: (any TextInputClient)?
    private var listener: ShellTextInputListener?

    /// Bind the manager and create a text input for `seat`. Returns nil when the
    /// compositor offers no text-input manager, which is a normal configuration —
    /// direct key events still reach fields, only composition is unavailable.
    public init?(client: ShellWaylandClient, seat: OpaquePointer) {
        guard let manager = unsafe client.proxy(.textInputManager) else { return nil }
        guard let textInput = unsafe zwp_text_input_manager_v3_get_text_input(
            manager, seat)
        else {
            return nil
        }
        unsafe self.textInput = textInput
        let listener = ShellTextInputListener(owner: self)
        self.listener = listener
        _ = unsafe ZwpTextInputV3Client.addListener(textInput, owner: listener)
    }

    isolated deinit {
        close()
    }

    /// Destroy the protocol object. Idempotent so host teardown and actor
    /// destruction may both call it.
    public func close() {
        guard let textInput = unsafe textInput else { return }
        if activeClient != nil, focusedSurface != 0 {
            unsafe zwp_text_input_v3_disable(textInput)
            commitState()
        }
        activeClient = nil
        focusedSurface = 0
        beginSessionEpoch()
        unsafe self.textInput = nil
        unsafe zwp_text_input_v3_destroy(textInput)
        // The proxy borrows the listener through its C user_data. Release the
        // Swift owner only after destroying that proxy.
        listener = nil
    }

    // MARK: - TextInputAdapter

    public func textInputDidActivate(_ client: any TextInputClient) {
        if let activeClient, activeClient !== client {
            textInputDidDeactivate(activeClient)
        }
        activeClient = client
        beginSessionEpoch()
        guard let textInput = unsafe textInput, focusedSurface != 0 else { return }
        unsafe zwp_text_input_v3_enable(textInput)
        applyState(for: client, cause: .other)
        commitState()
    }

    public func textInputDidDeactivate(_ client: any TextInputClient) {
        guard activeClient === client else { return }
        if let textInput = unsafe textInput, focusedSurface != 0 {
            unsafe zwp_text_input_v3_disable(textInput)
            commitState()
        }
        activeClient = nil
        beginSessionEpoch()
    }

    public func textInputDidChangeState(
        _ client: any TextInputClient,
        cause: TextInputChangeCause
    ) {
        guard activeClient === client else { return }
        guard !isApplyingDone else { return }
        guard focusedSurface != 0 else { return }
        applyState(for: client, cause: cause)
        commitState()
    }

    /// Stage the client's current state. Nothing reaches the compositor until
    /// `commitState`.
    private func applyState(
        for client: any TextInputClient,
        cause: TextInputChangeCause,
        surroundingContext: TextInputSurroundingContext? = nil
    ) {
        guard let textInput = unsafe textInput else { return }
        // A refusing client — a secure field — sends no surrounding text at all.
        // Sending an empty string instead would still tell the input method the
        // caret moved, which is more than a password field should reveal.
        if let context = surroundingContext
            ?? client.textInputSurroundingContext(),
           let wireContext = ShellTextInput.boundedSurroundingContext(
            context)
        {
            wireContext.text.withCString { pointer in
                unsafe zwp_text_input_v3_set_surrounding_text(
                    textInput, pointer,
                    wireContext.cursor,
                    wireContext.anchor)
            }
        }

        unsafe zwp_text_input_v3_set_text_change_cause(
            textInput,
            cause == .inputMethod
                ? UInt32(ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD.rawValue)
                : UInt32(ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER.rawValue)
        )

        unsafe zwp_text_input_v3_set_content_type(
            textInput,
            ShellTextInput.contentHint(client.textInputHints),
            ShellTextInput.contentPurpose(client.textInputContentType))

        guard let candidate = client.textInputCandidateGeometry,
              candidate.surfaceID.rawValue == UInt64(focusedSurface),
              let rectangle = ShellTextInput.wireRectangle(
                candidate.rect)
        else {
            return
        }
        unsafe zwp_text_input_v3_set_cursor_rectangle(
            textInput,
            rectangle.x,
            rectangle.y,
            rectangle.width,
            rectangle.height)
    }

    private func commitState() {
        guard let textInput = unsafe textInput else { return }
        unsafe zwp_text_input_v3_commit(textInput)
        committedStateSerial &+= 1
        validDoneSerials.insert(committedStateSerial)
    }

    // MARK: - Protocol events

    fileprivate func handleEnter(surfaceID: UInt) {
        guard surfaceID != 0, surfaceID != focusedSurface else { return }
        focusedSurface = surfaceID
        beginSessionEpoch()
        // A client that already has a focused field re-enables for the new
        // surface; otherwise the input method stays disabled until one is.
        if let activeClient, let textInput = unsafe textInput {
            unsafe zwp_text_input_v3_enable(textInput)
            applyState(for: activeClient, cause: .other)
            commitState()
        }
    }

    fileprivate func handleLeave(surfaceID: UInt) {
        guard surfaceID == focusedSurface else { return }
        if let textInput = unsafe textInput, activeClient != nil {
            unsafe zwp_text_input_v3_disable(textInput)
            commitState()
        }
        focusedSurface = 0
        beginSessionEpoch()
    }

    fileprivate func handlePreedit(text: String?, cursorBegin: Int32, cursorEnd: Int32) {
        pendingPreedit = (text ?? "", cursorBegin, cursorEnd)
    }

    fileprivate func handleCommitString(_ text: String?) {
        pendingCommitString = text ?? ""
    }

    fileprivate func handleDeleteSurrounding(before: UInt32, after: UInt32) {
        pendingDeleteBefore = before
        pendingDeleteAfter = after
    }

    fileprivate func handlePreeditHint(
        start: UInt32,
        end: UInt32,
        hint: UInt32
    ) {
        pendingPreeditHints.append((start, end, hint))
    }

    fileprivate func handleLanguage(_ language: String?) {
        pendingLanguage = language.flatMap { $0.isEmpty ? nil : $0 }
        pendingLanguageWasSet = true
    }

    fileprivate func handleAction(_ action: UInt32) {
        pendingAction = action
    }

    /// Apply everything staged since the last `done`.
    ///
    /// Order follows the protocol state machine exactly: remove the old
    /// preedit, delete surrounding text, commit, snapshot surrounding state,
    /// install the new preedit and cursor, then perform an action.
    fileprivate func handleDone(serial: UInt32) {
        defer { clearPending() }
        guard focusedSurface != 0,
              validDoneSerials.contains(serial),
              let client = activeClient
        else { return }

        isApplyingDone = true
        defer { isApplyingDone = false }
        if pendingLanguageWasSet {
            client.textInputDidChangeLanguage(pendingLanguage)
        }
        if client.hasMarkedText {
            client.unmarkText()
        }
        if pendingDeleteBefore > 0 || pendingDeleteAfter > 0 {
            client.deleteSurroundingText(
                beforeBytes: Int(pendingDeleteBefore), afterBytes: Int(pendingDeleteAfter))
        }
        if let commitString = pendingCommitString, !commitString.isEmpty {
            client.insertText(commitString)
        }
        // The surrounding snapshot is defined before the new preedit is
        // inserted. Secure clients continue to return nil here.
        let surrounding = client.textInputSurroundingContext()
        if let preedit = pendingPreedit {
            if preedit.text.isEmpty {
                client.unmarkText()
            } else {
                client.setMarkedText(
                    preedit.text,
                    selectedRange: ShellTextInput.preeditSelection(
                        preedit.text, begin: preedit.cursorBegin, end: preedit.cursorEnd))
                client.setMarkedTextStyles(
                    preeditStyles(for: preedit.text)
                )
            }
        }
        if pendingAction
            == UInt32(ZWP_TEXT_INPUT_V3_ACTION_SUBMIT.rawValue)
        {
            client.performTextInputAction()
        }

        // A mismatched serial still applies every incoming edit. It only
        // suppresses outbound state until a matching `done`.
        guard serial == committedStateSerial else { return }
        applyState(
            for: client,
            cause: .inputMethod,
            surroundingContext: surrounding
        )
        commitState()
    }

    private func clearPending() {
        pendingPreedit = nil
        pendingCommitString = nil
        pendingDeleteBefore = 0
        pendingDeleteAfter = 0
        pendingPreeditHints.removeAll(keepingCapacity: true)
        pendingAction = nil
        pendingLanguage = nil
        pendingLanguageWasSet = false
    }

    private func beginSessionEpoch() {
        sessionGeneration &+= 1
        precondition(
            sessionGeneration != 0,
            "text-input session generation exhausted")
        validDoneSerials.removeAll(keepingCapacity: true)
        clearPending()
    }

    private func preeditStyles(for text: String) -> [TextInputPreeditSpan] {
        pendingPreeditHints.map { hint in
            let lower = ShellTextInput.utf16Offset(
                in: text,
                forUTF8: Int(hint.start)
            )
            let upper = ShellTextInput.utf16Offset(
                in: text,
                forUTF8: Int(hint.end)
            )
            return TextInputPreeditSpan(
                range: min(lower, upper)..<max(lower, upper),
                style: ShellTextInput.preeditStyle(hint.hint)
            )
        }
    }

    private static func preeditStyle(_ hint: UInt32) -> TextInputPreeditStyle {
        switch hint {
        case UInt32(ZWP_TEXT_INPUT_V3_PREEDIT_HINT_SELECTION.rawValue):
            .selected
        case UInt32(ZWP_TEXT_INPUT_V3_PREEDIT_HINT_PREDICTION.rawValue):
            .highlighted
        case UInt32(ZWP_TEXT_INPUT_V3_PREEDIT_HINT_PREFIX.rawValue),
             UInt32(ZWP_TEXT_INPUT_V3_PREEDIT_HINT_SUFFIX.rawValue):
            .inactive
        case UInt32(ZWP_TEXT_INPUT_V3_PREEDIT_HINT_SPELLING_ERROR.rawValue),
             UInt32(ZWP_TEXT_INPUT_V3_PREEDIT_HINT_COMPOSE_ERROR.rawValue):
            .incorrect
        case UInt32(ZWP_TEXT_INPUT_V3_PREEDIT_HINT_WHOLE.rawValue):
            .active
        default:
            .none
        }
    }

    /// Convert the preedit cursor, given in UTF-8 bytes into the preedit string,
    /// into the UTF-16 range the framework indexes by. A negative pair means the
    /// cursor should be hidden, which we render as a caret at the end.
    static func preeditSelection(_ text: String, begin: Int32, end: Int32) -> Range<Int>? {
        guard begin >= 0, end >= 0 else { return nil }
        let lower = utf16Offset(in: text, forUTF8: Int(begin))
        let upper = utf16Offset(in: text, forUTF8: Int(end))
        return min(lower, upper)..<max(lower, upper)
    }

    static func utf16Offset(in text: String, forUTF8 offset: Int) -> Int {
        let clamped = min(max(0, offset), text.utf8.count)
        var index = text.utf8.index(
            text.utf8.startIndex,
            offsetBy: clamped)
        while index != text.utf8.startIndex,
              index.samePosition(in: text.unicodeScalars) == nil
        {
            text.utf8.formIndex(before: &index)
        }
        guard let scalarAligned = index.samePosition(
            in: text.unicodeScalars)
        else { return 0 }
        return text.utf16.distance(from: text.utf16.startIndex, to: scalarAligned)
    }

    static func boundedSurroundingContext(
        _ context: TextInputSurroundingContext,
        maximumBytes: Int = 4_000
    ) -> (text: String, cursor: Int32, anchor: Int32)? {
        guard maximumBytes > 0,
              let cursor = utf8Index(
                offset: context.cursorByteOffset,
                in: context.text),
              let anchor = utf8Index(
                offset: context.anchorByteOffset,
                in: context.text)
        else { return nil }
        let bytes = context.text.utf8
        if bytes.count <= maximumBytes {
            return (
                context.text,
                Int32(context.cursorByteOffset),
                Int32(context.anchorByteOffset))
        }

        let lower = min(
            context.cursorByteOffset,
            context.anchorByteOffset)
        let upper = max(
            context.cursorByteOffset,
            context.anchorByteOffset)
        guard upper - lower <= maximumBytes else { return nil }
        var startOffset = max(
            0,
            lower - (maximumBytes - (upper - lower)) / 2)
        var endOffset = min(
            bytes.count,
            startOffset + maximumBytes)
        if endOffset - startOffset < maximumBytes {
            startOffset = max(0, endOffset - maximumBytes)
        }
        while startOffset < lower,
              utf8Index(offset: startOffset, in: context.text) == nil
        {
            startOffset += 1
        }
        while endOffset > upper,
              utf8Index(offset: endOffset, in: context.text) == nil
        {
            endOffset -= 1
        }
        guard let start = utf8Index(
            offset: startOffset,
            in: context.text),
              let end = utf8Index(
                offset: endOffset,
                in: context.text),
              start <= cursor,
              cursor <= end,
              start <= anchor,
              anchor <= end
        else { return nil }
        return (
            String(context.text[start..<end]),
            Int32(context.cursorByteOffset - startOffset),
            Int32(context.anchorByteOffset - startOffset))
    }

    static func wireRectangle(
        _ rect: Rect
    ) -> (x: Int32, y: Int32, width: Int32, height: Int32)? {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite
        else { return nil }
        guard let x = wireCoordinate(rect.origin.x),
              let y = wireCoordinate(rect.origin.y),
              let width = wireCoordinate(
                max(1, rect.size.width)),
              let height = wireCoordinate(
                max(1, rect.size.height))
        else { return nil }
        return (x, y, max(1, width), max(1, height))
    }

    private static func utf8Index(
        offset: Int,
        in text: String
    ) -> String.Index? {
        guard offset >= 0, offset <= text.utf8.count else {
            return nil
        }
        let index = text.utf8.index(
            text.utf8.startIndex,
            offsetBy: offset)
        return index.samePosition(in: text)
    }

    private static func wireCoordinate(_ value: Double) -> Int32? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        guard rounded >= Double(Int32.min),
              rounded <= Double(Int32.max)
        else { return nil }
        return Int32(rounded)
    }

    // MARK: - Content type mapping

    /// The framework's neutral content type onto the protocol's purpose.
    static func contentPurpose(_ type: TextInputContentType) -> UInt32 {
        switch type {
        case .normal: return UInt32(ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL.rawValue)
        case .password: return UInt32(ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_PASSWORD.rawValue)
        case .pin: return UInt32(ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_PIN.rawValue)
        case .email: return UInt32(ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_EMAIL.rawValue)
        case .url: return UInt32(ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_URL.rawValue)
        case .number: return UInt32(ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NUMBER.rawValue)
        case .phone: return UInt32(ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_PHONE.rawValue)
        case .name: return UInt32(ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NAME.rawValue)
        case .search: return UInt32(ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL.rawValue)
        }
    }

    static func contentHint(_ hints: TextInputHints) -> UInt32 {
        var value: UInt32 = UInt32(ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE.rawValue)
        if hints.contains(.spellcheck) {
            value |= UInt32(ZWP_TEXT_INPUT_V3_CONTENT_HINT_SPELLCHECK.rawValue)
        }
        if hints.contains(.autocorrect) {
            value |= UInt32(ZWP_TEXT_INPUT_V3_CONTENT_HINT_COMPLETION.rawValue)
        }
        if hints.contains(.autocapitalize) {
            value |= UInt32(ZWP_TEXT_INPUT_V3_CONTENT_HINT_AUTO_CAPITALIZATION.rawValue)
        }
        if hints.contains(.multiline) {
            value |= UInt32(ZWP_TEXT_INPUT_V3_CONTENT_HINT_MULTILINE.rawValue)
        }
        if hints.contains(.sensitiveData) {
            // Both flags: `sensitive_data` asks the input method not to learn
            // from or log the content, `hidden_text` that it not display it.
            value |= UInt32(ZWP_TEXT_INPUT_V3_CONTENT_HINT_SENSITIVE_DATA.rawValue)
            value |= UInt32(ZWP_TEXT_INPUT_V3_CONTENT_HINT_HIDDEN_TEXT.rawValue)
        }
        return value
    }
}

/// Separate listener owner, matching the seat's pointer/keyboard boxes: the
/// generated dispatch is nonisolated and `addListener` borrows its owner.
@MainActor
final class ShellTextInputListener: ZwpTextInputV3Events {
    private unowned let owner: ShellTextInput

    init(owner: ShellTextInput) {
        self.owner = owner
    }

    nonisolated func enter(_ proxy: OpaquePointer, surface: OpaquePointer?) {
        // Wayland guarantees event arguments remain valid for the callback.
        // Convert the borrowed proxy identity to a scalar before actor handoff.
        let surfaceID = unsafe surface.map { UInt(bitPattern: $0) } ?? 0
        MainActor.assumeIsolated { owner.handleEnter(surfaceID: surfaceID) }
    }

    nonisolated func leave(_ proxy: OpaquePointer, surface: OpaquePointer?) {
        let surfaceID = unsafe surface.map { UInt(bitPattern: $0) } ?? 0
        MainActor.assumeIsolated { owner.handleLeave(surfaceID: surfaceID) }
    }

    nonisolated func preeditString(
        _ proxy: OpaquePointer, text: UnsafePointer<CChar>?,
        cursor_begin: Int32, cursor_end: Int32
    ) {
        // Protocol strings are nullable, NUL-terminated UTF-8 C strings borrowed for
        // this callback. Copy into Swift ownership before crossing actors.
        let value = unsafe text.map { unsafe String(cString: $0) }
        MainActor.assumeIsolated {
            owner.handlePreedit(text: value, cursorBegin: cursor_begin, cursorEnd: cursor_end)
        }
    }

    nonisolated func commitString(_ proxy: OpaquePointer, text: UnsafePointer<CChar>?) {
        let value = unsafe text.map { unsafe String(cString: $0) }
        MainActor.assumeIsolated { owner.handleCommitString(value) }
    }

    nonisolated func deleteSurroundingText(
        _ proxy: OpaquePointer, before_length: UInt32, after_length: UInt32
    ) {
        MainActor.assumeIsolated {
            owner.handleDeleteSurrounding(before: before_length, after: after_length)
        }
    }

    nonisolated func done(_ proxy: OpaquePointer, serial: UInt32) {
        MainActor.assumeIsolated { owner.handleDone(serial: serial) }
    }

    nonisolated func action(_ proxy: OpaquePointer, action: UInt32, serial: UInt32) {
        MainActor.assumeIsolated { owner.handleAction(action) }
    }
    nonisolated func language(_ proxy: OpaquePointer, language: UnsafePointer<CChar>?) {
        let value = unsafe language.map { unsafe String(cString: $0) }
        MainActor.assumeIsolated { owner.handleLanguage(value) }
    }
    nonisolated func preeditHint(
        _ proxy: OpaquePointer, start: UInt32, end: UInt32, hint: UInt32
    ) {
        MainActor.assumeIsolated {
            owner.handlePreeditHint(start: start, end: end, hint: hint)
        }
    }
}
