@_spi(NucleusCompositor) import NucleusLayers

@MainActor
public enum WindowRole: Sendable, Equatable {
    case application
    case shellChrome
    case notification
    case statusOverlay
    case hostedSurface
}

@MainActor
public enum WindowLevel: UInt32, Sendable {
    case desktop = 0
    case normal = 1
    case shellChrome = 2
    case overlay = 3
    case criticalOverlay = 4
}

/// `NSWindow.StyleMask`, verbatim. Modern AppKit shape with the legacy
/// borderless / nonactivatingPanel / texturedBackground bits intentionally
/// not modeled — they correspond to deprecated visual modes.
public struct WindowStyleMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let titled              = WindowStyleMask(rawValue: 1 << 0)
    public static let closable            = WindowStyleMask(rawValue: 1 << 1)
    public static let miniaturizable      = WindowStyleMask(rawValue: 1 << 2)
    public static let resizable           = WindowStyleMask(rawValue: 1 << 3)
    public static let fullSizeContentView = WindowStyleMask(rawValue: 1 << 4)
}

/// `NSWindow.TitlebarSeparatorStyle`, verbatim.
public enum TitlebarSeparatorStyle: Sendable, Equatable {
    case automatic, none, line, shadow
}

@MainActor
open class Window: Responder, ~Sendable {
    package let context: Context
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
    /// Implicit `VisualEffectView` with `material == .titlebar`. Mirrors
    /// `NSWindow.titlebar`: present when `styleMask.contains(.titled)`,
    /// `nil` otherwise. App code reads this to override the titlebar's
    /// `state` / `appearance` per-window.
    public internal(set) var titlebar: VisualEffectView?
    package var rootView: View?
    package weak var windowScene: WindowScene?
    public private(set) var contentViewController: ViewController?
    public private(set) var isVisible: Bool
    public private(set) var isKeyWindow: Bool
    public var firstResponder: Responder?

    public init(
        title: String = "",
        frame: Rect = .zero,
        role: WindowRole = .application,
        level: WindowLevel = .normal,
        styleMask: WindowStyleMask = [],
        participatesInHitTesting: Bool = true
    ) throws(UIError) {
        self.title = title
        self.frame = frame
        self.role = role
        self.level = level
        self.styleMask = styleMask
        self.titlebarAppearsTransparent = false
        self.titlebarSeparatorStyle = .automatic
        self.titlebar = nil
        self.participatesInHitTesting = participatesInHitTesting
        self.context = Application.currentContext
        self.rootView = nil
        self.windowScene = nil
        self.contentViewController = nil
        self.isVisible = false
        self.isKeyWindow = false
        self.firstResponder = nil
        try super.init()
        try syncTitlebarThrowing()
    }

    /// Allocate or clear `titlebar` to match the current `styleMask`.
    /// Idempotent; safe to call repeatedly. Mirrors `NSWindow`'s
    /// titlebar-on-demand allocation.
    private func syncTitlebarThrowing() throws(UIError) {
        if styleMask.contains(.titled) {
            if titlebar == nil {
                titlebar = try VisualEffectView(material: .titlebar)
            }
        } else {
            titlebar = nil
        }
    }

    /// Non-throwing wrapper for the `didSet` path. A `VisualEffectView`
    /// allocation failure in response to a property set is dropped on
    /// the floor (matches AppKit's never-fails titlebar accessor); the
    /// init path uses `syncTitlebarThrowing` directly so app code that
    /// constructs a titled window sees the error.
    private func syncTitlebar() {
        try? syncTitlebarThrowing()
    }

    public func setTitle(_ title: String) throws(UIError) {
        self.title = title
    }

    package func setRootView(_ view: View) throws(UIError) {
        // Eager Swift-tree update. The FFI insert journals into whatever
        // transaction is currently active for the context; the
        // consumer's flush trigger delivers it at the next frame
        // boundary.
        let preservesContentViewController = contentViewController?.rootView === view
        if !preservesContentViewController {
            contentViewController?.parentWindow = nil
            contentViewController = nil
        }
        if let oldRoot = rootView, oldRoot !== view {
            oldRoot.detachFromSwiftTree()
            oldRoot.backingLayer.detach()
            LayerTransaction.appendAmbient(.detached(oldRoot.backingLayer.id), in: context)
        }
        view.detachFromSwiftTree(clearOwningViewController: !preservesContentViewController)
        view.backingLayer.attach(to: nil, at: UInt32.max)
        rootView = view
        view.parentWindow = self
        if frame == .zero && view.frame != .zero {
            frame = view.frame
        } else {
            syncContentViewFrame()
        }
        if firstResponder == nil {
            firstResponder = view
        }
        LayerTransaction.appendAmbient(
            .inserted(layer: view.backingLayer.id, parent: nil, index: UInt32.max),
            in: context
        )
    }

    public func setFrame(_ frame: Rect, display shouldDisplay: Bool = true) throws(UIError) {
        self.frame = frame
        syncContentViewFrame()
        if shouldDisplay {
            rootView?.setNeedsDisplay()
        }
        try contentViewController?.viewDidLayout()
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

    public func setContentView(_ view: View?) throws(UIError) {
        if let view {
            try setRootView(view)
        } else if let oldRoot = rootView {
            contentViewController?.parentWindow = nil
            contentViewController = nil
            try oldRoot.removeFromSuperview()
        }
    }

    public func setContentViewController(_ controller: ViewController) throws(UIError) {
        contentViewController?.parentWindow = nil
        contentViewController = controller
        controller.parentWindow = self
        try controller.loadViewIfNeeded()
        let contentView = try controller.view
        try setRootView(contentView)
        contentView.owningViewController = controller
    }

    public func orderFront(_ sender: Any? = nil) throws(UIError) {
        _ = sender
        if let windowScene {
            try windowScene.orderFront(self)
        } else {
            try setVisible(true)
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

    public func dispatchEvent(_ event: Event) throws(UIError) -> EventHandling {
        guard let rootView else {
            return .notHandled
        }
        return try EventDispatcher.dispatch(event, from: rootView)
    }

    open override var nextResponder: Responder? {
        get { explicitNextResponder }
        set { explicitNextResponder = newValue }
    }

    package func setVisible(_ visible: Bool) throws(UIError) {
        guard isVisible != visible else {
            return
        }
        isVisible = visible
        if visible {
            try contentViewController?.viewWillAppear()
        } else {
            setOrderedOut()
        }
    }

    package func setKey(_ key: Bool) {
        isKeyWindow = key
    }

    package func setOrderedOut() {
        isVisible = false
        isKeyWindow = false
    }

    private func syncContentViewFrame() {
        rootView?.frame = frame
    }
}
