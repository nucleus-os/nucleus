package import NucleusCompositorServer

package protocol WindowRole: AnyObject {
    var windowID: UInt64 { get }
}

package struct XdgToplevelID: Hashable, Sendable {
    package let rawValue: UInt64

    package init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

@MainActor
package final class XdgRole: WindowRole {
    package let xdgToplevelID: XdgToplevelID
    package let windowID: UInt64
    package var parentWindowID: UInt64?
    package var requestedFullscreenTarget: UInt64?

    package init(xdgToplevelID: XdgToplevelID, windowID: UInt64) {
        self.xdgToplevelID = xdgToplevelID
        self.windowID = windowID
    }
}

@MainActor
package final class XwaylandRole: WindowRole {
    package let windowID: UInt64
    package let x11WindowID: UInt64
    package var title: String = ""
    package var windowClass: String = ""
    package var windowInstance: String = ""
    package var overrideRedirect: Bool
    package var transientForX11WindowID: UInt64?
    package var parentWindowID: UInt64?
    package var protocols: XwaylandProtocols = []
    package var hints: XwaylandHints = .init()
    package var focusModel: XwaylandFocusModel = .passive
    package var windowTypes: XwaylandWindowType = []
    package var netState: XwaylandNetState = []
    package var processID: UInt32?
    package var userTime: UInt32 = 0
    package var urgent: Bool = false
    package var decorationsOff: Bool = false

    package init(
        windowID: UInt64, x11WindowID: UInt64, overrideRedirect: Bool, wantsKeyboardFocus: Bool
    ) {
        self.windowID = windowID
        self.x11WindowID = x11WindowID
        self.overrideRedirect = overrideRedirect
        self.focusModel = wantsKeyboardFocus ? .passive : .noInput
    }

    package var wantsKeyboardFocus: Bool {
        if overrideRedirect {
            return windowTypes.wantsOverrideRedirectFocus
        }
        return focusModel != .noInput
    }
}

extension WindowManager {
    @discardableResult
    package func xdgCreated(xdgToplevelID: XdgToplevelID) -> UInt64 {
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

    package func xdgDestroyed(windowID: UInt64) {
        if let toplevelID = xdgToplevelByWindow.removeValue(forKey: windowID) {
            xdgWindowByToplevel[toplevelID] = nil
        }
        xdgRolesByWindow[windowID] = nil
    }

    package func xdgSetParent(windowID: UInt64, parentWindowID: UInt64?) {
        xdgRole(windowID: windowID)?.parentWindowID = parentWindowID
        server.window(id: windowID)?.parentWindowID = parentWindowID
    }

    package func xdgRequestFullscreen(windowID: UInt64, target: UInt64?) {
        guard let window = server.window(id: windowID) else { return }
        window.requestedFullscreen = true
        window.fullscreenTarget = target.map { .output($0) } ?? .automatic
        xdgRole(windowID: windowID)?.requestedFullscreenTarget = target
    }

    package func xdgUnsetFullscreen(windowID: UInt64) {
        guard let window = server.window(id: windowID) else { return }
        window.requestedFullscreen = false
        window.fullscreenTarget = .automatic
        xdgRole(windowID: windowID)?.requestedFullscreenTarget = nil
    }

    package func xdgRequestMaximize(windowID: UInt64, requested: Bool) {
        server.window(id: windowID)?.requestedMaximized = requested
    }

    package func xdgRole(windowID: UInt64) -> XdgRole? {
        xdgRolesByWindow[windowID]
    }

    @discardableResult
    package func xwaylandCreated(
        x11WindowID: UInt64, overrideRedirect: Bool, wantsKeyboardFocus: Bool
    ) -> UInt64 {
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

    package func xwaylandDestroyed(windowID: UInt64) {
        if let xid = xwaylandXIDByWindow.removeValue(forKey: windowID) {
            xwaylandWindowByXID[xid] = nil
        }
        xwaylandRolesByWindow[windowID] = nil
    }

    package func xwaylandSetTitle(windowID: UInt64, title: String) {
        xwaylandRole(windowID: windowID)?.title = title
        // Mirror into the model's normalized metadata (the single home the
        // foreign-toplevel projection reads); the role keeps the raw X11 value.
        server.window(id: windowID)?.title = title
    }

    package func xwaylandSetClass(windowID: UInt64, windowClass: String) {
        xwaylandRole(windowID: windowID)?.windowClass = windowClass
        // X11 has no app-id; its WM_CLASS class is the closest analog.
        server.window(id: windowID)?.appId = windowClass
    }

    package func xwaylandSetClass(windowID: UInt64, windowClass: String, instance: String) {
        guard let role = xwaylandRole(windowID: windowID) else { return }
        role.windowClass = windowClass
        role.windowInstance = instance
        server.window(id: windowID)?.appId = windowClass
    }

    package func xwaylandRole(windowID: UInt64) -> XwaylandRole? {
        xwaylandRolesByWindow[windowID]
    }

    /// Create (or return the existing) model window for a zwlr layer surface,
    /// resolved by its surface wire id. Layer surfaces are borderless, unmanaged,
    /// non-focusing by default, and z-banded by their layer (background/bottom below
    /// normal windows, top/overlay above) via `Window.level`. `createWindow` inserts
    /// at the default level, so the window is re-stacked into its band here.
    @discardableResult
    package func layerShellCreated(surfaceObjectId: UInt32, layer: UInt32) -> UInt64 {
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

package func layerShellLevel(_ layer: UInt32) -> Int32 {
    switch layer {
    case 0: return -1000
    case 1: return -100
    case 2: return 100
    case 3: return 200
    default: return 0
    }
}
