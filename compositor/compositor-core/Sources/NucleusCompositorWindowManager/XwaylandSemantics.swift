import NucleusTypes
import NucleusCompositorServerTypes
import NucleusCompositorServer

@MainActor
extension WindowManager {
    public func xwaylandApplyMetadata(windowID: UInt64, metadata: XwaylandWindowMetadata) {
        guard let role = xwaylandRole(windowID: windowID),
              let window = server.window(id: windowID)
        else { return }

        role.overrideRedirect = metadata.overrideRedirect
        role.transientForX11WindowID = metadata.transientForX11WindowID
        role.parentWindowID = metadata.transientForX11WindowID.flatMap { parentXID in
            xwaylandWindowByXID[parentXID]
        }
        window.parentWindowID = role.parentWindowID
        role.protocols = metadata.protocols
        role.hints = metadata.hints
        role.focusModel = metadata.hints.focusModel(protocols: metadata.protocols)
        role.windowTypes = metadata.windowTypes
        role.netState = metadata.netState
        role.processID = metadata.processID
        role.userTime = metadata.userTime
        role.urgent = metadata.hints.urgent || metadata.netState.contains(.demandsAttention)
        role.decorationsOff = metadata.hints.decorationsOff

        window.managedAppWindow = !metadata.overrideRedirect &&
            metadata.windowTypes.intersection(XwaylandWindowType([.dock, .desktop, .notification, .tooltip])).isEmpty
        window.wantsKeyboardFocus = role.wantsKeyboardFocus
        window.requestedFullscreen = metadata.netState.contains(.fullscreen)
        window.requestedMaximized = !window.requestedFullscreen && metadata.netState.maximized
        window.level = metadata.netState.contains(.above) ? 1 : (metadata.netState.contains(.below) ? -1 : 0)
    }

    public func xwaylandNetStateSnapshot(windowID: UInt64) -> XwaylandNetState {
        guard let role = xwaylandRole(windowID: windowID) else { return [] }
        var state = role.netState
        if let window = server.window(id: windowID) {
            if window.requestedFullscreen || window.activeFullscreen {
                state.insert(.fullscreen)
            } else {
                state.remove(.fullscreen)
            }
            if window.requestedMaximized || window.activeMaximized {
                state.insert(.maximizedVert)
                state.insert(.maximizedHorz)
            } else {
                state.remove(.maximizedVert)
                state.remove(.maximizedHorz)
            }
        }
        if activeXwaylandWindowID == windowID {
            state.insert(.focused)
        } else {
            state.remove(.focused)
        }
        role.netState = state
        return state
    }

    public func xwaylandHandleStateRequest(_ request: XwaylandStateRequest) -> XwaylandStatePlan {
        guard let role = xwaylandRole(windowID: request.windowID),
              let window = server.window(id: request.windowID)
        else { return XwaylandStatePlan() }

        var state = xwaylandNetStateSnapshot(windowID: request.windowID)
        var requestConfigure = false

        func target(_ bit: XwaylandNetState) -> Bool? {
            if !request.states.contains(bit) { return nil }
            switch request.action {
            case 0: return false
            case 1: return true
            case 2: return !state.contains(bit)
            default: return nil
            }
        }

        if let fullscreen = target(.fullscreen) {
            requestConfigure = true
            window.requestedFullscreen = fullscreen
            if fullscreen {
                window.requestedMaximized = false
                state.insert(.fullscreen)
                state.remove(.maximizedVert)
                state.remove(.maximizedHorz)
            } else {
                window.fullscreenTarget = .automatic
                state.remove(.fullscreen)
            }
        }

        let maximizedTarget = target(.maximizedVert) ?? target(.maximizedHorz)
        if let maximized = maximizedTarget {
            requestConfigure = true
            window.requestedMaximized = maximized && !window.requestedFullscreen
            if window.requestedMaximized {
                state.insert(.maximizedVert)
                state.insert(.maximizedHorz)
            } else {
                state.remove(.maximizedVert)
                state.remove(.maximizedHorz)
            }
        }

        for semanticBit in [
            XwaylandNetState.hidden,
            .above,
            .below,
            .demandsAttention,
            .modal,
            .skipTaskbar,
            .skipPager,
            .sticky,
        ] {
            guard let enabled = target(semanticBit) else { continue }
            if enabled {
                state.insert(semanticBit)
            } else {
                state.remove(semanticBit)
            }
        }

        window.level = state.contains(.above) ? 1 : (state.contains(.below) ? -1 : 0)
        role.netState = state
        role.urgent = state.contains(.demandsAttention)

        return XwaylandStatePlan(
            handled: requestConfigure || !request.states.isEmpty,
            requestConfigure: requestConfigure,
            activate: requestConfigure,
            raise: requestConfigure || state.contains(.above),
            requestedFullscreen: window.requestedFullscreen,
            requestedMaximized: window.requestedMaximized,
            netState: xwaylandNetStateSnapshot(windowID: request.windowID)
        )
    }

    public func xwaylandFocusPlan(windowID: UInt64) -> XwaylandFocusPlan {
        guard let role = xwaylandRole(windowID: windowID) else {
            return XwaylandFocusPlan(actions: UInt32(xwaylandFocusDenied))
        }

        if role.overrideRedirect && !role.wantsKeyboardFocus {
            let activeWindowID = activeXwaylandWindowID
            return XwaylandFocusPlan(
                actions: UInt32(xwaylandFocusDenied),
                activeX11Window: activeXwaylandXID(),
                previousX11Window: activeXwaylandXID(),
                focusedX11Window: activeXwaylandXID(),
                deniedSyncState: activeWindowID.map { xwaylandNetStateSnapshot(windowID: $0).rawValue } ?? 0
            )
        }

        let previous = activeXwaylandXID()
        activeXwaylandWindowID = windowID
        var actions: UInt32 = 0
        switch role.focusModel {
        case .passive:
            actions |= UInt32(xwaylandFocusSetInput)
        case .locallyActive:
            actions |= UInt32(xwaylandFocusSetInput)
            actions |= UInt32(xwaylandFocusTakeFocus)
        case .globallyActive:
            actions |= UInt32(xwaylandFocusTakeFocus)
        case .noInput:
            break
        }

        return XwaylandFocusPlan(
            actions: actions,
            activeX11Window: role.x11WindowID,
            previousX11Window: previous,
            focusedX11Window: role.x11WindowID
        )
    }

    public func xwaylandClearFocusPlan() -> XwaylandFocusPlan {
        let previous = activeXwaylandXID()
        activeXwaylandWindowID = nil
        return XwaylandFocusPlan(
            actions: UInt32(xwaylandFocusClear),
            activeX11Window: 0,
            previousX11Window: previous,
            focusedX11Window: 0
        )
    }

    public func xwaylandClosePlan(windowID: UInt64) -> XwaylandClosePlan {
        guard let role = xwaylandRole(windowID: windowID) else { return XwaylandClosePlan() }
        return XwaylandClosePlan(
            action: role.protocols.contains(.deleteWindow)
                ? UInt32(xwaylandCloseDeleteWindow)
                : UInt32(xwaylandCloseDestroy)
        )
    }

    public func xwaylandClientListIncludes(windowID: UInt64) -> Bool {
        guard let role = xwaylandRole(windowID: windowID),
              let window = server.window(id: windowID)
        else { return false }
        return !role.overrideRedirect && window.managedAppWindow
    }

    public func activeXwaylandXID() -> UInt64 {
        guard let activeXwaylandWindowID,
              let xid = xwaylandXIDByWindow[activeXwaylandWindowID]
        else { return 0 }
        return xid
    }
}
