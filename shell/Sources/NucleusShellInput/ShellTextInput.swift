import WaylandClientC
import WaylandClientDispatch
import NucleusShellWayland
import NucleusUI

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
/// echoes back in `done`. State applied from a `done` whose serial is stale must
/// be discarded, which is what `pendingSerial`/`doneSerial` track.
@MainActor
public final class ShellTextInput: TextInputAdapter {
    private let textInput: OpaquePointer
    /// The surface this text input is scoped to, set from `enter`.
    private var focusedSurface: UInt = 0

    /// Serial of the last `commit` sent, and of the last `done` received.
    private var pendingSerial: UInt32 = 0
    private var doneSerial: UInt32 = 0

    /// Preedit and commit arrive before `done` and apply on it — the protocol
    /// batches a composition update across several events.
    private var pendingPreedit: (text: String, cursorBegin: Int32, cursorEnd: Int32)?
    private var pendingCommitString: String?
    private var pendingDeleteBefore: UInt32 = 0
    private var pendingDeleteAfter: UInt32 = 0

    private weak var activeClient: (any TextInputClient)?
    private var listener: ShellTextInputListener?

    /// Bind the manager and create a text input for `seat`. Returns nil when the
    /// compositor offers no text-input manager, which is a normal configuration —
    /// direct key events still reach fields, only composition is unavailable.
    public init?(client: ShellWaylandClient, seat: OpaquePointer) {
        guard let manager = client.proxy(.textInputManager) else { return nil }
        guard let textInput = zwp_text_input_manager_v3_get_text_input(manager, seat) else {
            return nil
        }
        self.textInput = textInput
        let listener = ShellTextInputListener(owner: self)
        self.listener = listener
        _ = ZwpTextInputV3Client.addListener(textInput, owner: listener)
    }

    deinit {
        // The proxy is @MainActor-confined state; releasing it here would cross
        // an isolation boundary, so destruction is explicit via `close()`.
    }

    /// Destroy the protocol object. Explicit rather than in `deinit` because the
    /// proxy is actor-confined.
    public func close() {
        zwp_text_input_v3_destroy(textInput)
    }

    // MARK: - TextInputAdapter

    public func textInputDidActivate(_ client: any TextInputClient) {
        activeClient = client
        zwp_text_input_v3_enable(textInput)
        applyState(for: client)
        commitState()
    }

    public func textInputDidDeactivate(_ client: any TextInputClient) {
        guard activeClient === client else { return }
        activeClient = nil
        zwp_text_input_v3_disable(textInput)
        commitState()
    }

    public func textInputDidChangeState(_ client: any TextInputClient) {
        guard activeClient === client else { return }
        applyState(for: client)
        commitState()
    }

    /// Stage the client's current state. Nothing reaches the compositor until
    /// `commitState`.
    private func applyState(for client: any TextInputClient) {
        // A refusing client — a secure field — sends no surrounding text at all.
        // Sending an empty string instead would still tell the input method the
        // caret moved, which is more than a password field should reveal.
        if let context = client.textInputSurroundingContext() {
            context.text.withCString { pointer in
                zwp_text_input_v3_set_surrounding_text(
                    textInput, pointer,
                    Int32(context.cursorByteOffset), Int32(context.anchorByteOffset))
            }
        }

        zwp_text_input_v3_set_content_type(
            textInput,
            ShellTextInput.contentHint(client.textInputHints),
            ShellTextInput.contentPurpose(client.textInputContentType))

        let caret = client.textInputCaretRect
        zwp_text_input_v3_set_cursor_rectangle(
            textInput,
            Int32(caret.origin.x), Int32(caret.origin.y),
            Int32(max(1, caret.size.width)), Int32(max(1, caret.size.height)))
    }

    private func commitState() {
        zwp_text_input_v3_commit(textInput)
        pendingSerial &+= 1
    }

    // MARK: - Protocol events

    fileprivate func handleEnter(surfaceID: UInt) {
        focusedSurface = surfaceID
        // A client that already has a focused field re-enables for the new
        // surface; otherwise the input method stays disabled until one is.
        if let activeClient {
            zwp_text_input_v3_enable(textInput)
            applyState(for: activeClient)
            commitState()
        }
    }

    fileprivate func handleLeave(surfaceID: UInt) {
        guard surfaceID == focusedSurface else { return }
        focusedSurface = 0
        zwp_text_input_v3_disable(textInput)
        commitState()
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

    /// Apply everything staged since the last `done`.
    ///
    /// Order is fixed by the protocol: delete first, then commit, then preedit.
    /// Doing it in any other order corrupts offsets that were computed against
    /// the pre-delete text.
    fileprivate func handleDone(serial: UInt32) {
        doneSerial = serial
        defer { clearPending() }

        // A `done` for a state the client has already moved past must be
        // discarded: its offsets refer to text that no longer exists.
        guard serial == pendingSerial else { return }
        guard let client = activeClient else { return }

        if pendingDeleteBefore > 0 || pendingDeleteAfter > 0 {
            client.deleteSurroundingText(
                beforeBytes: Int(pendingDeleteBefore), afterBytes: Int(pendingDeleteAfter))
        }
        if let commitString = pendingCommitString, !commitString.isEmpty {
            client.insertText(commitString)
        }
        if let preedit = pendingPreedit {
            if preedit.text.isEmpty {
                client.unmarkText()
            } else {
                client.setMarkedText(
                    preedit.text,
                    selectedRange: ShellTextInput.preeditSelection(
                        preedit.text, begin: preedit.cursorBegin, end: preedit.cursorEnd))
            }
        }
    }

    private func clearPending() {
        pendingPreedit = nil
        pendingCommitString = nil
        pendingDeleteBefore = 0
        pendingDeleteAfter = 0
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
        guard let index = text.utf8.index(
            text.utf8.startIndex, offsetBy: clamped, limitedBy: text.utf8.endIndex),
              let scalarAligned = index.samePosition(in: text.unicodeScalars)
        else { return text.utf16.count }
        return text.utf16.distance(from: text.utf16.startIndex, to: scalarAligned)
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
        let surfaceID = surface.map { UInt(bitPattern: $0) } ?? 0
        MainActor.assumeIsolated { owner.handleEnter(surfaceID: surfaceID) }
    }

    nonisolated func leave(_ proxy: OpaquePointer, surface: OpaquePointer?) {
        let surfaceID = surface.map { UInt(bitPattern: $0) } ?? 0
        MainActor.assumeIsolated { owner.handleLeave(surfaceID: surfaceID) }
    }

    nonisolated func preeditString(
        _ proxy: OpaquePointer, text: UnsafePointer<CChar>?,
        cursor_begin: Int32, cursor_end: Int32
    ) {
        let value = text.map { String(cString: $0) }
        MainActor.assumeIsolated {
            owner.handlePreedit(text: value, cursorBegin: cursor_begin, cursorEnd: cursor_end)
        }
    }

    nonisolated func commitString(_ proxy: OpaquePointer, text: UnsafePointer<CChar>?) {
        let value = text.map { String(cString: $0) }
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

    nonisolated func action(_ proxy: OpaquePointer, action: UInt32, serial: UInt32) {}
    nonisolated func language(_ proxy: OpaquePointer, language: UnsafePointer<CChar>?) {}
    nonisolated func preeditHint(
        _ proxy: OpaquePointer, start: UInt32, end: UInt32, hint: UInt32
    ) {}
}
