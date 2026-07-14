@MainActor
open class ViewController: Responder, ~Sendable {
    private var loaded = false
    private var storedView: View?
    public var representedObject: Any?
    package weak var parentWindow: Window?

    public override init() throws(UIError) {
        try super.init()
    }

    public convenience init(view: View) throws(UIError) {
        try self.init()
        setView(view)
    }

    open func loadView() throws(UIError) {
        storedView = try View()
    }

    open func viewDidLoad() throws(UIError) {}
    open func viewWillAppear() throws(UIError) {}
    open func viewDidLayout() throws(UIError) {}

    public var view: View {
        get throws(UIError) {
            try loadViewIfNeeded()
            return storedView!
        }
    }

    package var rootView: View? {
        storedView
    }

    public func setView(_ view: View) {
        storedView?.owningViewController = nil
        storedView = view
        view.owningViewController = self
        loaded = true
    }

    package func clearLoadedView() {
        storedView = nil
        loaded = false
    }

    public func loadViewIfNeeded() throws(UIError) {
        guard !loaded else { return }
        try loadView()
        storedView?.owningViewController = self
        loaded = true
        try viewDidLoad()
    }

    open override var nextResponder: Responder? {
        get { parentWindow ?? explicitNextResponder }
        set { explicitNextResponder = newValue }
    }
}
