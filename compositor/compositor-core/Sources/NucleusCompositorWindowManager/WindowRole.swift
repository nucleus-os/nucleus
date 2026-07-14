import NucleusCompositorServer

public protocol WindowRole: AnyObject {
    var windowID: UInt64 { get }
}

@MainActor
public final class XdgRole: WindowRole {
    public let xdgToplevelID: UInt64
    public let windowID: UInt64
    public var parentWindowID: UInt64?
    public var requestedFullscreenTarget: UInt64?

    public init(xdgToplevelID: UInt64, windowID: UInt64) {
        self.xdgToplevelID = xdgToplevelID
        self.windowID = windowID
    }
}

@MainActor
public final class XwaylandRole: WindowRole {
    public let windowID: UInt64
    public let x11WindowID: UInt64
    public var title: String = ""
    public var windowClass: String = ""
    public var windowInstance: String = ""
    public var overrideRedirect: Bool
    public var transientForX11WindowID: UInt64?
    public var parentWindowID: UInt64?
    public var protocols: XwaylandProtocols = []
    public var hints: XwaylandHints = .init()
    public var focusModel: XwaylandFocusModel = .passive
    public var windowTypes: XwaylandWindowType = []
    public var netState: XwaylandNetState = []
    public var processID: UInt32?
    public var userTime: UInt32 = 0
    public var urgent: Bool = false
    public var decorationsOff: Bool = false

    public init(windowID: UInt64, x11WindowID: UInt64, overrideRedirect: Bool, wantsKeyboardFocus: Bool) {
        self.windowID = windowID
        self.x11WindowID = x11WindowID
        self.overrideRedirect = overrideRedirect
        self.focusModel = wantsKeyboardFocus ? .passive : .noInput
    }

    public var wantsKeyboardFocus: Bool {
        if overrideRedirect {
            return windowTypes.wantsOverrideRedirectFocus
        }
        return focusModel != .noInput
    }
}

extension WindowManager {
    @discardableResult
    public func xdgCreated(xdgToplevelID: UInt64) -> UInt64 {
        if let windowID = xdgWindowByToplevel[xdgToplevelID] {
            return windowID
        }
        let window = server.createWindow(source: .xdg)
        let role = XdgRole(xdgToplevelID: xdgToplevelID, windowID: window.id)
        xdgRolesByWindow[window.id] = role
        xdgWindowByToplevel[xdgToplevelID] = window.id
        xdgToplevelByWindow[window.id] = xdgToplevelID
        return window.id
    }

    public func xdgDestroyed(windowID: UInt64) {
        if let toplevelID = xdgToplevelByWindow.removeValue(forKey: windowID) {
            xdgWindowByToplevel[toplevelID] = nil
        }
        xdgRolesByWindow[windowID] = nil
    }

    public func xdgSetParent(windowID: UInt64, parentWindowID: UInt64?) {
        xdgRole(windowID: windowID)?.parentWindowID = parentWindowID
        server.window(id: windowID)?.parentWindowID = parentWindowID
    }

    public func xdgRequestFullscreen(windowID: UInt64, target: UInt64?) {
        guard let window = server.window(id: windowID) else { return }
        window.requestedFullscreen = true
        window.fullscreenTarget = target.map { .output($0) } ?? .automatic
        xdgRole(windowID: windowID)?.requestedFullscreenTarget = target
    }

    public func xdgUnsetFullscreen(windowID: UInt64) {
        guard let window = server.window(id: windowID) else { return }
        window.requestedFullscreen = false
        window.fullscreenTarget = .automatic
        xdgRole(windowID: windowID)?.requestedFullscreenTarget = nil
    }

    public func xdgRequestMaximize(windowID: UInt64, requested: Bool) {
        server.window(id: windowID)?.requestedMaximized = requested
    }

    public func xdgRole(windowID: UInt64) -> XdgRole? {
        xdgRolesByWindow[windowID]
    }

    @discardableResult
    public func xwaylandCreated(x11WindowID: UInt64, overrideRedirect: Bool, wantsKeyboardFocus: Bool) -> UInt64 {
        if let windowID = xwaylandWindowByXID[x11WindowID] {
            return windowID
        }
        let window = server.createWindow(source: .xwayland)
        window.managedAppWindow = true
        window.wantsKeyboardFocus = wantsKeyboardFocus
        let role = XwaylandRole(
            windowID: window.id,
            x11WindowID: x11WindowID,
            overrideRedirect: overrideRedirect,
            wantsKeyboardFocus: wantsKeyboardFocus
        )
        xwaylandRolesByWindow[window.id] = role
        xwaylandWindowByXID[x11WindowID] = window.id
        xwaylandXIDByWindow[window.id] = x11WindowID
        return window.id
    }

    public func xwaylandDestroyed(windowID: UInt64) {
        if let xid = xwaylandXIDByWindow.removeValue(forKey: windowID) {
            xwaylandWindowByXID[xid] = nil
        }
        xwaylandRolesByWindow[windowID] = nil
    }

    public func xwaylandSetTitle(windowID: UInt64, title: String) {
        xwaylandRole(windowID: windowID)?.title = title
        // Mirror into the model's normalized metadata (the single home the
        // foreign-toplevel projection reads); the role keeps the raw X11 value.
        server.window(id: windowID)?.title = title
    }

    public func xwaylandSetClass(windowID: UInt64, windowClass: String) {
        xwaylandRole(windowID: windowID)?.windowClass = windowClass
        // X11 has no app-id; its WM_CLASS class is the closest analog.
        server.window(id: windowID)?.appId = windowClass
    }

    public func xwaylandSetClass(windowID: UInt64, windowClass: String, instance: String) {
        guard let role = xwaylandRole(windowID: windowID) else { return }
        role.windowClass = windowClass
        role.windowInstance = instance
        server.window(id: windowID)?.appId = windowClass
    }

    public func xwaylandRole(windowID: UInt64) -> XwaylandRole? {
        xwaylandRolesByWindow[windowID]
    }

    /// Create (or return the existing) model window for a zwlr layer surface,
    /// resolved by its surface wire id. Layer surfaces are borderless, unmanaged,
    /// non-focusing by default, and z-banded by their layer (background/bottom below
    /// normal windows, top/overlay above) via `Window.level`. `createWindow` inserts
    /// at the default level, so the window is re-stacked into its band here.
    @discardableResult
    public func layerShellCreated(surfaceObjectId: UInt32, layer: UInt32) -> UInt64 {
        if let existing = server.windows.window(bySurfaceObjectId: surfaceObjectId),
            existing.source == .layerShell
        {
            return existing.id
        }
        let window = server.createWindow(source: .layerShell)
        window.surfaceObjectId = surfaceObjectId
        window.managedAppWindow = false
        window.wantsKeyboardFocus = false
        window.level = layerShellLevel(layer)
        server.windows.restackByLevel(id: window.id)
        return window.id
    }

}

public func layerShellLevel(_ layer: UInt32) -> Int32 {
    switch layer {
    case 0: return -1000
    case 1: return -100
    case 2: return 100
    case 3: return 200
    default: return 0
    }
}
