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
    /// The responder keyboard events route to. Set through
    /// `makeFirstResponder(_:)` so both sides get their lifecycle callbacks.
    public private(set) var firstResponder: Responder?

    public init(
        title: String = "",
        frame: Rect = .zero,
        role: WindowRole = .application,
        level: WindowLevel = .normal,
        styleMask: WindowStyleMask = [],
        participatesInHitTesting: Bool = true
    ) {
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
        super.init()
        syncTitlebar()
    }

    /// Allocate or clear `titlebar` to match the current `styleMask`.
    /// Idempotent; safe to call repeatedly. Mirrors `NSWindow`'s
    /// titlebar-on-demand allocation.
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
        if firstResponder == nil, view.acceptsFirstResponder {
            firstResponder = view
        }
        LayerTransaction.appendAmbient(
            .inserted(layer: view.backingLayer.id, parent: nil, index: UInt32.max),
            in: context
        )
    }

    public func setFrame(_ frame: Rect, display shouldDisplay: Bool = true) {
        self.frame = frame
        syncContentViewFrame()
        if shouldDisplay {
            rootView?.setNeedsDisplay()
        }
        contentViewController?.viewDidLayout()
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
        set { explicitNextResponder = newValue }
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
    /// Returns whether focus moved. Mirrors `NSWindow.makeFirstResponder(_:)`:
    /// the outgoing responder may refuse to resign (a field with invalid
    /// content), and the incoming one may refuse to accept.
    @discardableResult
    public func makeFirstResponder(_ responder: Responder?) -> Bool {
        if firstResponder === responder { return true }
        if let current = firstResponder, !current.resignFirstResponder() {
            return false
        }
        guard let responder else {
            firstResponder = nil
            return true
        }
        guard responder.becomeFirstResponder() else {
            // The outgoing responder already resigned, so focus lands nowhere
            // rather than silently staying put — otherwise a refused move would
            // leave a resigned responder still receiving keys.
            firstResponder = nil
            return false
        }
        firstResponder = responder
        return true
    }

    /// Route a key event to the first responder and up its chain. Returns
    /// whether anything handled it.
    @discardableResult
    package func deliverKeyEvent(_ event: Event) -> EventHandling {
        guard let firstResponder else { return .notHandled }
        return firstResponder.deliverEvent(event)
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
