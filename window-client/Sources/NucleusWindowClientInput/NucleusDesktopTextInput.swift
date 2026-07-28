import WaylandClientDispatch
import WaylandProtocolTypes
@_spi(NucleusWindowClientImplementation)
public import NucleusWindowClientWayland
public import NucleusUI

/// The desktop client's `zwp_text_input_v3` client, wired to NucleusUI's input-method seam.
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
@safe public final class NucleusDesktopTextInput: TextInputAdapter {
    // The Wayland proxy is owned by this object from successful construction
    // through `close()`. All access stays on the main actor, the generated
    // listener borrows `listener`, and the proxy is destroyed before that
    // listener owner is released.
    private var textInput: WaylandProxy<ZwpTextInputV3Client>?
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
    private var listener: NucleusDesktopTextInputListener?

    /// Bind the manager and create a text input for `seat`. Returns nil when the
    /// compositor offers no text-input manager, which is a normal configuration —
    /// direct key events still reach fields, only composition is unavailable.
    public init?(
        client: NucleusDesktopConnection,
        seat: WaylandProxy<WlSeatClient>
    ) {
        guard let manager = client.textInputManager else { return nil }
        guard let textInput = try? manager.getTextInput(seat: seat)
        else {
            return nil
        }
        self.textInput = textInput
        let listener = NucleusDesktopTextInputListener(owner: self)
        self.listener = listener
        do {
            try textInput.installListener(listener)
        } catch {
            try? textInput.destroy()
            return nil
        }
    }

    isolated deinit {
        close()
    }

    /// Destroy the protocol object. Idempotent so host teardown and actor
    /// destruction may both call it.
    public func close() {
        guard let textInput else { return }
        if activeClient != nil, focusedSurface != 0 {
            try? textInput.disable()
            commitState()
        }
        activeClient = nil
        focusedSurface = 0
        beginSessionEpoch()
        self.textInput = nil
        try? textInput.destroy()
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
        guard let textInput, focusedSurface != 0 else { return }
        try? textInput.enable()
        applyState(for: client, cause: .other)
        commitState()
    }

    public func textInputDidDeactivate(_ client: any TextInputClient) {
        guard activeClient === client else { return }
        if let textInput, focusedSurface != 0 {
            try? textInput.disable()
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
        guard let textInput else { return }
        // A refusing client — a secure field — sends no surrounding text at all.
        // Sending an empty string instead would still tell the input method the
        // caret moved, which is more than a password field should reveal.
        if let context = surroundingContext
            ?? client.textInputSurroundingContext(),
           let wireContext = NucleusDesktopTextInput.boundedSurroundingContext(
            context)
        {
            try? textInput.setSurroundingText(
                text: wireContext.text,
                cursor: wireContext.cursor,
                anchor: wireContext.anchor)
        }

        try? textInput.setTextChangeCause(
            cause: cause == .inputMethod
                ? .inputMethod
                : .other)

        try? textInput.setContentType(
            hint: ZwpTextInputV3ContentHint(
                rawValue: NucleusDesktopTextInput.contentHint(
                    client.textInputHints)),
            purpose: ZwpTextInputV3ContentPurpose(
                rawValue: NucleusDesktopTextInput.contentPurpose(
                    client.textInputContentType)))

        guard let candidate = client.textInputCandidateGeometry,
              candidate.surfaceID.rawValue == UInt64(focusedSurface),
              let rectangle = NucleusDesktopTextInput.wireRectangle(
                candidate.rect)
        else {
            return
        }
        try? textInput.setCursorRectangle(
            x: rectangle.x,
            y: rectangle.y,
            width: rectangle.width,
            height: rectangle.height)
    }

    private func commitState() {
        guard let textInput else { return }
        try? textInput.commit()
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
        if let activeClient, let textInput {
            try? textInput.enable()
            applyState(for: activeClient, cause: .other)
            commitState()
        }
    }

    fileprivate func handleLeave(surfaceID: UInt) {
        guard surfaceID == focusedSurface else { return }
        if let textInput, activeClient != nil {
            try? textInput.disable()
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
                    selectedRange: NucleusDesktopTextInput.preeditSelection(
                        preedit.text, begin: preedit.cursorBegin, end: preedit.cursorEnd))
                client.setMarkedTextStyles(
                    preeditStyles(for: preedit.text)
                )
            }
        }
        if pendingAction
            == ZwpTextInputV3Action.submit.rawValue
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
            let lower = NucleusDesktopTextInput.utf16Offset(
                in: text,
                forUTF8: Int(hint.start)
            )
            let upper = NucleusDesktopTextInput.utf16Offset(
                in: text,
                forUTF8: Int(hint.end)
            )
            return TextInputPreeditSpan(
                range: min(lower, upper)..<max(lower, upper),
                style: NucleusDesktopTextInput.preeditStyle(hint.hint)
            )
        }
    }

    private static func preeditStyle(_ hint: UInt32) -> TextInputPreeditStyle {
        switch hint {
        case ZwpTextInputV3PreeditHint.selection.rawValue:
            .selected
        case ZwpTextInputV3PreeditHint.prediction.rawValue:
            .highlighted
        case ZwpTextInputV3PreeditHint.prefix.rawValue,
             ZwpTextInputV3PreeditHint.suffix.rawValue:
            .inactive
        case ZwpTextInputV3PreeditHint.spellingError.rawValue,
             ZwpTextInputV3PreeditHint.composeError.rawValue:
            .incorrect
        case ZwpTextInputV3PreeditHint.whole.rawValue:
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
        case .normal: return ZwpTextInputV3ContentPurpose.normal.rawValue
        case .password: return ZwpTextInputV3ContentPurpose.password.rawValue
        case .pin: return ZwpTextInputV3ContentPurpose.pin.rawValue
        case .email: return ZwpTextInputV3ContentPurpose.email.rawValue
        case .url: return ZwpTextInputV3ContentPurpose.url.rawValue
        case .number: return ZwpTextInputV3ContentPurpose.number.rawValue
        case .phone: return ZwpTextInputV3ContentPurpose.phone.rawValue
        case .name: return ZwpTextInputV3ContentPurpose.name.rawValue
        case .search: return ZwpTextInputV3ContentPurpose.normal.rawValue
        }
    }

    static func contentHint(_ hints: TextInputHints) -> UInt32 {
        var value = ZwpTextInputV3ContentHint.none
        if hints.contains(.spellcheck) {
            value.insert(.spellcheck)
        }
        if hints.contains(.autocorrect) {
            value.insert(.completion)
        }
        if hints.contains(.autocapitalize) {
            value.insert(.autoCapitalization)
        }
        if hints.contains(.multiline) {
            value.insert(.multiline)
        }
        if hints.contains(.sensitiveData) {
            // Both flags: `sensitive_data` asks the input method not to learn
            // from or log the content, `hidden_text` that it not display it.
            value.insert(.sensitiveData)
            value.insert(.hiddenText)
        }
        return value.rawValue
    }
}

/// Separate listener owner, matching the seat's pointer/keyboard boxes.
@MainActor
final class NucleusDesktopTextInputListener: ZwpTextInputV3Events {
    private unowned let owner: NucleusDesktopTextInput

    init(owner: NucleusDesktopTextInput) {
        self.owner = owner
    }

    func enter(
        _ proxy: WaylandBorrowedProxy<ZwpTextInputV3Client>,
        surface: WaylandBorrowedProxy<WlSurfaceClient>
    ) {
        owner.handleEnter(surfaceID: surface.identity)
    }

    func leave(
        _ proxy: WaylandBorrowedProxy<ZwpTextInputV3Client>,
        surface: WaylandBorrowedProxy<WlSurfaceClient>
    ) {
        owner.handleLeave(surfaceID: surface.identity)
    }

    func preeditString(
        _ proxy: WaylandBorrowedProxy<ZwpTextInputV3Client>, text: String?,
        cursor_begin: Int32, cursor_end: Int32
    ) {
        owner.handlePreedit(
            text: text, cursorBegin: cursor_begin, cursorEnd: cursor_end)
    }

    func commitString(
        _ proxy: WaylandBorrowedProxy<ZwpTextInputV3Client>, text: String?
    ) {
        owner.handleCommitString(text)
    }

    func deleteSurroundingText(
        _ proxy: WaylandBorrowedProxy<ZwpTextInputV3Client>, before_length: UInt32, after_length: UInt32
    ) {
        owner.handleDeleteSurrounding(
            before: before_length,
            after: after_length)
    }

    func done(_ proxy: WaylandBorrowedProxy<ZwpTextInputV3Client>, serial: UInt32) {
        owner.handleDone(serial: serial)
    }

    func action(
        _ proxy: WaylandBorrowedProxy<ZwpTextInputV3Client>,
        action: ZwpTextInputV3Action,
        serial: UInt32
    ) {
        owner.handleAction(action.rawValue)
    }
    func language(
        _ proxy: WaylandBorrowedProxy<ZwpTextInputV3Client>,
        language: String
    ) {
        owner.handleLanguage(language)
    }
    func preeditHint(
        _ proxy: WaylandBorrowedProxy<ZwpTextInputV3Client>,
        start: UInt32, end: UInt32,
        hint: ZwpTextInputV3PreeditHint
    ) {
        owner.handlePreeditHint(
            start: start, end: end, hint: hint.rawValue)
    }
}
