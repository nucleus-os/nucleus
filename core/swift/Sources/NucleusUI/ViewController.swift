@MainActor
open class ViewController: Responder, ~Sendable {
    private var loaded = false
    private var storedView: View?
    public var representedObject: Any?
    package weak var parentWindow: Window?

    public override init() {
        super.init()
    }

    public convenience init(view: View) {
        self.init()
        setView(view)
    }

    open func loadView() {
        storedView = View()
    }

    open func viewDidLoad() {}
    open func viewWillAppear() {}
    open func viewDidLayout() {}

    public var view: View {
        get {
            loadViewIfNeeded()
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

    public func loadViewIfNeeded() {
        guard !loaded else { return }
        loadView()
        storedView?.owningViewController = self
        loaded = true
        viewDidLoad()
    }

    open override var nextResponder: Responder? {
        get { parentWindow ?? explicitNextResponder }
        set { explicitNextResponder = newValue }
    }
}
