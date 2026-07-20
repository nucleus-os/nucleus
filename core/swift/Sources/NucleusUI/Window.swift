@_spi(NucleusCompositor) import NucleusLayers

public enum WindowRole: Sendable, Equatable {
    case application
    case layer
    case popup
    case notification
    case overlay
    case lock
    case hostedContent
}

public enum WindowLevel: UInt32, Sendable {
    case desktop = 0
    case normal = 1
    case shellChrome = 2
    case overlay = 3
    case criticalOverlay = 4
}

/// The supported `NSWindow.StyleMask`-shaped subset. Legacy borderless,
/// nonactivating-panel, and textured-background behavior is intentionally not
/// modeled.
public struct WindowStyleMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let titled              = WindowStyleMask(rawValue: 1 << 0)
    public static let closable            = WindowStyleMask(rawValue: 1 << 1)
    public static let miniaturizable      = WindowStyleMask(rawValue: 1 << 2)
    public static let resizable           = WindowStyleMask(rawValue: 1 << 3)
    public static let fullSizeContentView = WindowStyleMask(rawValue: 1 << 4)
}

/// The supported `NSWindow.TitlebarSeparatorStyle`-shaped vocabulary.
public enum TitlebarSeparatorStyle: Sendable, Equatable {
    case automatic, none, line, shadow
}

@MainActor
open class Window: Responder, ~Sendable {
    public let id: WindowID
    public let accessibilityID: AccessibilityID
    package let uiContext: UIContext
    public private(set) var title: String
    public private(set) var frame: Rect
    public var role: WindowRole
    public var level: WindowLevel
    public var participatesInHitTesting: Bool
    /// `NSWindow.styleMask`. Toggling `.titled` allocates / clears the
    /// implicit `titlebar` `VisualEffectView`. Parenting the titlebar
    /// view into a visible layer tree (for Wayland-managed windows
    /// with server-side decorations) is a separate compositor-side
    /// concern; see "Server-side decoration backdrop" in
    /// `docs/backdrop-appkit-redesign.md`.
    public var styleMask: WindowStyleMask {
        didSet {
            if styleMask.contains(.titled) != oldValue.contains(.titled) {
                syncTitlebar()
            }
        }
    }
    /// `NSWindow.titlebarAppearsTransparent`.
    public var titlebarAppearsTransparent: Bool
    /// `NSWindow.titlebarSeparatorStyle`.
    public var titlebarSeparatorStyle: TitlebarSeparatorStyle
    /// Implicit `VisualEffectView` with `material == .titlebar`, present when
    /// `styleMask.contains(.titled)` and `nil` otherwise.
    public internal(set) var titlebar: VisualEffectView?
    package var rootView: View?
    package weak var windowScene: WindowScene?
    public private(set) var contentViewController: ViewController?
    public private(set) var isVisible: Bool
    public private(set) var isKeyWindow: Bool
    /// The responder keyboard events route to. Set through
    /// `makeFirstResponder(_:)` so both sides get their lifecycle callbacks.
    public private(set) var firstResponder: Responder?
    package var focusScopeRecords: [FocusScopeRecord]
    /// Platform surface currently presenting this window. Hosts update this on
    /// surface enter/configure/leave; portable UI code reads it only through
    /// named coordinate conversions such as text candidate geometry.
    public private(set) var surfaceAssociation: WindowSurfaceAssociation?

    /// Routes composed text between this window's focused text client and the
    /// platform's input method. Per-window because focus is per-window; an
    /// embedder installs one adapter on each window it hosts.
    public let textInputContext = TextInputContext()

    /// Install the platform text-input adapter for this hosted window.
    public func installTextInputAdapter(_ adapter: (any TextInputAdapter)?) {
        textInputContext.installAdapter(adapter)
    }

    public init(
        title: String = "",
        frame: Rect = .zero,
        role: WindowRole = .application,
        level: WindowLevel = .normal,
        styleMask: WindowStyleMask = [],
        participatesInHitTesting: Bool = true
    ) {
        precondition(
            frame.isFinite
                && frame.size.width >= 0
                && frame.size.height >= 0,
            "a window frame must be finite with nonnegative dimensions")
        let uiContext = Application.currentUIContext
        self.id = uiContext.allocateWindowID()
        self.accessibilityID = uiContext.allocateAccessibilityID()
        self.uiContext = uiContext
        self.title = title
        self.frame = frame
        self.role = role
        self.level = level
        self.styleMask = styleMask
        self.titlebarAppearsTransparent = false
        self.titlebarSeparatorStyle = .automatic
        self.titlebar = nil
        self.participatesInHitTesting = participatesInHitTesting
        self.rootView = nil
        self.windowScene = nil
        self.contentViewController = nil
        self.isVisible = false
        self.isKeyWindow = false
        self.firstResponder = nil
        self.focusScopeRecords = []
        self.surfaceAssociation = nil
        super.init()
        syncTitlebar()
    }

    /// Allocate or clear `titlebar` to match the current `styleMask`.
    /// Idempotent and safe to call repeatedly.
    private func syncTitlebar() {
        if styleMask.contains(.titled) {
            if titlebar == nil {
                titlebar = VisualEffectView(material: .titlebar)
            }
        } else {
            titlebar = nil
        }
    }

    public func setTitle(_ title: String) {
        self.title = title
    }

    package func setRootView(_ view: View) {
        precondition(
            view.uiContext === uiContext,
            "a window cannot adopt content from another UIContext")
        let preservesContentViewController = contentViewController?.rootView === view
        if !preservesContentViewController {
            contentViewController?.parentWindow = nil
            contentViewController = nil
        }
        if let oldRoot = rootView, oldRoot !== view {
            oldRoot.detachFromSwiftTree()
        }
        view.detachFromSwiftTree(clearOwningViewController: !preservesContentViewController)
        rootView = view
        view.parentWindow = self
        if frame == .zero && view.frame != .zero {
            frame = view.frame
        }
        syncContentViewFrame()
        if firstResponder == nil, view.acceptsFirstResponder {
            _ = makeFirstResponder(view)
        }
    }

    public func setFrame(_ frame: Rect, display shouldDisplay: Bool = true) {
        precondition(
            frame.isFinite
                && frame.size.width >= 0
                && frame.size.height >= 0,
            "a window frame must be finite with nonnegative dimensions")
        self.frame = frame
        syncContentViewFrame()
        if shouldDisplay {
            rootView?.setNeedsDisplay()
        }
        contentViewController?.viewDidLayout()
    }

    public func scenePoint(fromWindow point: Point) -> Point {
        Point(
            x: point.x + frame.origin.x,
            y: point.y + frame.origin.y
        )
    }

    public func windowPoint(fromScene point: Point) -> Point {
        Point(
            x: point.x - frame.origin.x,
            y: point.y - frame.origin.y
        )
    }

    public func sceneRect(fromWindow rect: Rect) -> Rect {
        Rect(origin: scenePoint(fromWindow: rect.origin), size: rect.size)
    }

    public func windowRect(fromScene rect: Rect) -> Rect {
        Rect(origin: windowPoint(fromScene: rect.origin), size: rect.size)
    }

    public func setSurfaceAssociation(_ association: WindowSurfaceAssociation?) {
        guard surfaceAssociation != association else { return }
        surfaceAssociation = association
        if let activeClient = textInputContext.activeClient {
            textInputContext.invalidateState(for: activeClient)
        }
    }

    public var stableHandle: Handle {
        Handle(window: self)
    }

    public var root: View? {
        rootView
    }

    public var contentView: View? {
        rootView
    }

    public func setContentView(_ view: View?) {
        if let view {
            setRootView(view)
        } else if let oldRoot = rootView {
            contentViewController?.parentWindow = nil
            contentViewController = nil
            oldRoot.removeFromSuperview()
        }
    }

    public func setContentViewController(_ controller: ViewController) {
        contentViewController?.parentWindow = nil
        contentViewController = controller
        controller.parentWindow = self
        controller.loadViewIfNeeded()
        let contentView = controller.view
        setRootView(contentView)
        contentView.owningViewController = controller
    }

    public func orderFront(_ sender: Any? = nil) {
        _ = sender
        if let windowScene {
            windowScene.orderFront(self)
        } else {
            setVisible(true)
        }
    }

    public func orderOut(_ sender: Any? = nil) {
        _ = sender
        if let windowScene {
            windowScene.orderOut(self)
        } else {
            setOrderedOut()
        }
    }

    public func makeKey() {
        windowScene?.makeKey(self) ?? setKey(true)
    }

    /// Route an event within this window: keyboard-like events to the first
    /// responder, pointer events by hit test.
    @discardableResult
    public func dispatchEvent(_ event: Event) -> EventHandling {
        if event.isKeyEvent { return deliverKeyEvent(event) }
        guard let rootView else { return .notHandled }
        return rootView.dispatchEvent(event)
    }

    open override var nextResponder: Responder? {
        get { explicitNextResponder }
        set { setExplicitNextResponder(newValue) }
    }

    package func setVisible(_ visible: Bool) {
        guard isVisible != visible else {
            return
        }
        isVisible = visible
        if visible {
            contentViewController?.viewWillAppear()
        } else {
            setOrderedOut()
        }
    }

    // MARK: - First responder

    /// Move keyboard focus to `responder`, honouring both sides' refusals.
    ///
    /// Returns whether focus moved. Corresponds to `NSWindow.makeFirstResponder(_:)`:
    /// the outgoing responder may refuse to resign (a field with invalid
    /// content), and the incoming one may refuse to accept.
    @discardableResult
    public func makeFirstResponder(_ responder: Responder?) -> Bool {
        if firstResponder === responder { return true }
        if let responder,
           !responderBelongsToActiveFocusScope(responder)
        {
            return false
        }
        let previousView = firstResponder as? View
        if let current = firstResponder, !current.resignFirstResponder() {
            return false
        }
        guard let responder else {
            firstResponder = nil
            previousView?.focusStateDidChange()
            uiContext.postAccessibilityNotification(
                AccessibilityNotification(kind: .focus))
            return true
        }
        guard responder.becomeFirstResponder() else {
            // The outgoing responder already resigned, so focus lands nowhere
            // rather than silently staying put — otherwise a refused move would
            // leave a resigned responder still receiving keys.
            firstResponder = nil
            previousView?.focusStateDidChange()
            uiContext.postAccessibilityNotification(
                AccessibilityNotification(kind: .focus))
            return false
        }
        firstResponder = responder
        previousView?.focusStateDidChange()
        let nextView = responder as? View
        nextView?.focusStateDidChange()
        uiContext.postAccessibilityNotification(
            AccessibilityNotification(
                kind: .focus,
                target: nextView?.accessibilityID))
        return true
    }

    /// Route a key event to the first responder and up its chain. Returns
    /// whether anything handled it.
    @discardableResult
    package func deliverKeyEvent(_ event: Event) -> EventHandling {
        if event.type == .keyDown,
           event.keyCode == .return,
           !(firstResponder is Button),
           let button = rootView?.defaultButton()
        {
            button.performPress()
            return .handled
        }
        let routed = firstResponder?.deliverEvent(event) ?? .notHandled
        guard routed == .notHandled,
              event.type == .keyDown,
              event.keyCode == .return,
              let button = rootView?.defaultButton()
        else { return routed }
        button.performPress()
        return .handled
    }

    package func setKey(_ key: Bool) {
        isKeyWindow = key
    }

    package func setOrderedOut() {
        isVisible = false
        isKeyWindow = false
    }

    private func syncContentViewFrame() {
        rootView?.frame = Rect(origin: .zero, size: frame.size)
    }
}
