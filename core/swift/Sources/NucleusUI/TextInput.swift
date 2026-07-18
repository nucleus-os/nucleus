/// What kind of text a field expects, so an input method can adapt — a
/// different keyboard layout, autocorrect off, candidates suppressed.
///
/// Named for what the field *is*, not for any protocol's enumeration. It maps
/// onto `zwp_text_input_v3`'s content purpose at the adapter, and would map onto
/// a different vocabulary on another platform; `core/` resolves no Wayland
/// dependency and must not adopt its names.
public enum TextInputContentType: Sendable, Equatable {
    case normal
    /// Obscured entry. Adapters must also treat this as "no surrounding text,
    /// no learning, no candidate display".
    case password
    case pin
    case email
    case url
    case number
    case phone
    case name
    case search
}

/// Behaviours a field asks the input method for, orthogonal to content type.
public struct TextInputHints: OptionSet, Sendable, Hashable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let spellcheck = TextInputHints(rawValue: 1 << 0)
    public static let autocorrect = TextInputHints(rawValue: 1 << 1)
    public static let autocapitalize = TextInputHints(rawValue: 1 << 2)
    /// The field must never be learned from or logged by the input method.
    public static let sensitiveData = TextInputHints(rawValue: 1 << 3)
    public static let multiline = TextInputHints(rawValue: 1 << 4)
}

/// The text around the caret, as an input method needs to see it. Offsets are
/// UTF-8 byte offsets into `text`, which is the convention every input-method
/// protocol uses.
public struct TextInputSurroundingContext: Sendable, Equatable {
    public var text: String
    public var cursorByteOffset: Int
    public var anchorByteOffset: Int

    public init(text: String, cursorByteOffset: Int, anchorByteOffset: Int) {
        self.text = text
        self.cursorByteOffset = cursorByteOffset
        self.anchorByteOffset = anchorByteOffset
    }
}

/// A view that can receive composed text from an input method.
///
/// The platform-neutral half of the seam, shaped after `NSTextInputClient`. An
/// adapter — the shell's `zwp_text_input_v3` driver, the compositor's server-side
/// binding, a test — drives a client through this protocol and never touches the
/// view's internals.
@MainActor
public protocol TextInputClient: AnyObject {
    /// Commit final text, replacing any composition and any selection.
    func insertText(_ string: String)

    /// Install or update provisional composition text. `selectedRange` is
    /// relative to `string`.
    func setMarkedText(_ string: String, selectedRange: Range<Int>?)

    /// Abandon the composition without committing it.
    func unmarkText()

    var hasMarkedText: Bool { get }
    var markedRange: Range<Int>? { get }
    var selectedRange: Range<Int> { get }

    /// Delete around the caret, in UTF-8 bytes, at the input method's request.
    func deleteSurroundingText(beforeBytes: Int, afterBytes: Int)

    /// Context for composition, or `nil` when the client refuses to provide it.
    /// A secure field always refuses.
    func textInputSurroundingContext() -> TextInputSurroundingContext?

    /// Where to place candidate UI, in the client's own coordinate space. The
    /// adapter converts to surface coordinates.
    var textInputCaretRect: Rect { get }

    var textInputContentType: TextInputContentType { get }
    var textInputHints: TextInputHints { get }
}

/// The platform half of the seam: what an adapter must implement to carry a
/// client's state out to a real input method.
///
/// Deliberately not a protocol the *client* calls directly — the client talks to
/// `TextInputContext`, which is what lets a field work identically with no
/// adapter attached at all (as it does in tests, and in a session with no input
/// method running).
@MainActor
public protocol TextInputAdapter: AnyObject {
    /// An input method should now be active for `client`.
    func textInputDidActivate(_ client: any TextInputClient)
    /// No client is focused; the input method should be disabled.
    func textInputDidDeactivate(_ client: any TextInputClient)
    /// The client's text, selection, or caret rectangle changed, so the input
    /// method's cached state is stale.
    func textInputDidChangeState(_ client: any TextInputClient)
}

/// Routes between the focused text client and the platform's input method.
///
/// One instance per UI context. A field activates itself here on becoming first
/// responder and deactivates on resigning; the platform adapter, if any,
/// observes. With no adapter attached, everything still works — direct key
/// events reach the field regardless, and only composition is unavailable.
@MainActor
public final class TextInputContext {
    /// The adapter for this context, installed by the embedder. `nil` in tests
    /// and in sessions with no input method.
    public weak var adapter: (any TextInputAdapter)?

    /// The client currently accepting composed text.
    public private(set) weak var activeClient: (any TextInputClient)?

    public init() {}

    public func activate(_ client: any TextInputClient) {
        guard activeClient !== client else { return }
        if let activeClient {
            adapter?.textInputDidDeactivate(activeClient)
        }
        activeClient = client
        adapter?.textInputDidActivate(client)
    }

    public func deactivate(_ client: any TextInputClient) {
        guard activeClient === client else { return }
        activeClient = nil
        adapter?.textInputDidDeactivate(client)
    }

    /// Tell the input method its cached view of the client is stale. Called by a
    /// field whenever its text, selection, or caret position changes.
    public func invalidateState(for client: any TextInputClient) {
        guard activeClient === client else { return }
        adapter?.textInputDidChangeState(client)
    }
}
