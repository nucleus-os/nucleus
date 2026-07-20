/// Platform data-exchange seam used by editing controls.
///
/// A host installs an adapter backed by Wayland data-control/data-device,
/// NSPasteboard, Android ClipboardManager, or another platform service. The
/// deterministic in-process fallback keeps copy/paste useful in headless
/// scenes and tests without pretending to provide cross-process exchange.
@MainActor
public protocol PasteboardAdapter: AnyObject {
    func readString() -> String?
    func writeString(_ string: String)
    func clear()
}

@MainActor
public final class Pasteboard {
    public static let general = Pasteboard()

    public weak var adapter: (any PasteboardAdapter)?
    private var localString: String?

    public init() {}

    public var string: String? {
        get { adapter?.readString() ?? localString }
        set {
            localString = newValue
            if let newValue {
                adapter?.writeString(newValue)
            } else {
                adapter?.clear()
            }
        }
    }

    public func clear() {
        string = nil
    }
}
