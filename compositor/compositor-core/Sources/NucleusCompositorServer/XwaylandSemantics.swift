package import NucleusCompositorServerTypes
import NucleusTypes

package struct XwaylandProtocols: OptionSet, Sendable, Equatable {
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package static let deleteWindow = XwaylandProtocols(
        rawValue: UInt32(xwaylandProtocolDeleteWindow))
    package static let takeFocus = XwaylandProtocols(rawValue: UInt32(xwaylandProtocolTakeFocus))
    package static let ping = XwaylandProtocols(rawValue: UInt32(xwaylandProtocolPing))
    package static let syncRequest = XwaylandProtocols(
        rawValue: UInt32(xwaylandProtocolSyncRequest))
}

package struct XwaylandWindowType: OptionSet, Sendable, Equatable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static let normal = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeNormal))
    package static let dialog = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeDialog))
    package static let utility = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeUtility))
    package static let toolbar = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeToolbar))
    package static let splash = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeSplash))
    package static let menu = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeMenu))
    package static let dropdownMenu = XwaylandWindowType(
        rawValue: UInt64(xwaylandWindowTypeDropdownMenu))
    package static let popupMenu = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypePopupMenu))
    package static let tooltip = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeTooltip))
    package static let notification = XwaylandWindowType(
        rawValue: UInt64(xwaylandWindowTypeNotification))
    package static let dock = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeDock))
    package static let desktop = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeDesktop))
    package static let dragAndDrop = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeDnd))
    package static let combo = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeCombo))

    package var wantsOverrideRedirectFocus: Bool {
        !intersection(XwaylandWindowType([.popupMenu, .dropdownMenu, .combo, .dragAndDrop])).isEmpty
    }
}

package struct XwaylandNetState: OptionSet, Sendable, Equatable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static let fullscreen = XwaylandNetState(rawValue: UInt64(xwaylandNetStateFullscreen))
    package static let maximizedVert = XwaylandNetState(
        rawValue: UInt64(xwaylandNetStateMaximizedVert))
    package static let maximizedHorz = XwaylandNetState(
        rawValue: UInt64(xwaylandNetStateMaximizedHorz))
    package static let hidden = XwaylandNetState(rawValue: UInt64(xwaylandNetStateHidden))
    package static let above = XwaylandNetState(rawValue: UInt64(xwaylandNetStateAbove))
    package static let below = XwaylandNetState(rawValue: UInt64(xwaylandNetStateBelow))
    package static let demandsAttention = XwaylandNetState(
        rawValue: UInt64(xwaylandNetStateDemandsAttention))
    package static let modal = XwaylandNetState(rawValue: UInt64(xwaylandNetStateModal))
    package static let skipTaskbar = XwaylandNetState(rawValue: UInt64(xwaylandNetStateSkipTaskbar))
    package static let skipPager = XwaylandNetState(rawValue: UInt64(xwaylandNetStateSkipPager))
    package static let sticky = XwaylandNetState(rawValue: UInt64(xwaylandNetStateSticky))
    package static let focused = XwaylandNetState(rawValue: UInt64(xwaylandNetStateFocused))

    package var maximized: Bool {
        contains(.maximizedVert) || contains(.maximizedHorz)
    }
}

package enum XwaylandFocusModel: UInt32, Sendable, Equatable {
    case noInput
    case passive
    case locallyActive
    case globallyActive

    package init(input: Bool, takeFocus: Bool) {
        switch (input, takeFocus) {
        case (true, false): self = .passive
        case (true, true): self = .locallyActive
        case (false, true): self = .globallyActive
        case (false, false): self = .noInput
        }
    }
}

package struct XwaylandHints: Sendable, Equatable {
    package var input: Bool
    package var urgent: Bool
    package var decorationsOff: Bool

    package init(input: Bool = true, urgent: Bool = false, decorationsOff: Bool = false) {
        self.input = input
        self.urgent = urgent
        self.decorationsOff = decorationsOff
    }

    package func focusModel(protocols: XwaylandProtocols) -> XwaylandFocusModel {
        XwaylandFocusModel(input: input, takeFocus: protocols.contains(.takeFocus))
    }
}

package struct XwaylandWindowMetadata: Sendable, Equatable {
    package var x11WindowID: UInt64
    package var transientForX11WindowID: UInt64?
    package var windowTypes: XwaylandWindowType
    package var netState: XwaylandNetState
    package var protocols: XwaylandProtocols
    package var processID: UInt32?
    package var userTime: UInt32
    package var overrideRedirect: Bool
    package var hints: XwaylandHints

    /// Field-wise init: the Swift-native XWM constructs this directly from the XCB
    /// event/property data (no wire ABI round-trip).
    package init(
        x11WindowID: UInt64,
        transientForX11: UInt64,
        windowTypeMask: UInt64,
        netStateMask: UInt64,
        protocolMask: UInt32,
        pid: UInt32,
        userTime: UInt32,
        overrideRedirect: Bool,
        inputHint: Bool,
        urgent: Bool,
        decorationsOff: Bool
    ) {
        self.x11WindowID = x11WindowID
        self.transientForX11WindowID = transientForX11 == 0 ? nil : transientForX11
        self.windowTypes = XwaylandWindowType(rawValue: windowTypeMask)
        self.netState = XwaylandNetState(rawValue: netStateMask)
        self.protocols = XwaylandProtocols(rawValue: protocolMask)
        self.processID = pid == 0 ? nil : pid
        self.userTime = userTime
        self.overrideRedirect = overrideRedirect
        self.hints = XwaylandHints(input: inputHint, urgent: urgent, decorationsOff: decorationsOff)
    }
}

package struct XwaylandStateRequest: Sendable, Equatable {
    package var windowID: UInt64
    package var action: UInt32
    package var states: XwaylandNetState
    package var sourceIndication: UInt32

    /// Field-wise init: the Swift-native XWM constructs this directly from the XCB
    /// event/property data (no wire ABI round-trip).
    package init(windowID: UInt64, action: UInt32, stateMask: UInt64, sourceIndication: UInt32) {
        self.windowID = windowID
        self.action = action
        self.states = XwaylandNetState(rawValue: stateMask)
        self.sourceIndication = sourceIndication
    }
}

package struct XwaylandStatePlan: Sendable, Equatable {
    package var handled: Bool = false
    package var requestConfigure: Bool = false
    package var activate: Bool = false
    package var raise: Bool = false
    package var requestedFullscreen: Bool = false
    package var requestedMaximized: Bool = false
    package var netState: XwaylandNetState = []

    package init(
        handled: Bool = false,
        requestConfigure: Bool = false,
        activate: Bool = false,
        raise: Bool = false,
        requestedFullscreen: Bool = false,
        requestedMaximized: Bool = false,
        netState: XwaylandNetState = []
    ) {
        self.handled = handled
        self.requestConfigure = requestConfigure
        self.activate = activate
        self.raise = raise
        self.requestedFullscreen = requestedFullscreen
        self.requestedMaximized = requestedMaximized
        self.netState = netState
    }
}

package struct XwaylandFocusPlan: Sendable, Equatable {
    package var actions: UInt32 = 0
    package var activeX11Window: UInt64 = 0
    package var previousX11Window: UInt64 = 0
    package var focusedX11Window: UInt64 = 0
    package var deniedSyncState: UInt64 = 0

    package init(
        actions: UInt32 = 0,
        activeX11Window: UInt64 = 0,
        previousX11Window: UInt64 = 0,
        focusedX11Window: UInt64 = 0,
        deniedSyncState: UInt64 = 0
    ) {
        self.actions = actions
        self.activeX11Window = activeX11Window
        self.previousX11Window = previousX11Window
        self.focusedX11Window = focusedX11Window
        self.deniedSyncState = deniedSyncState
    }
}

package struct XwaylandClosePlan: Sendable, Equatable {
    package var action: UInt32 = UInt32(xwaylandCloseNone)

    package init(action: UInt32 = UInt32(xwaylandCloseNone)) {
        self.action = action
    }
}
