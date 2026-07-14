import NucleusTypes
import NucleusCompositorServerTypes

public struct XwaylandProtocols: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let deleteWindow = XwaylandProtocols(rawValue: UInt32(xwaylandProtocolDeleteWindow))
    public static let takeFocus = XwaylandProtocols(rawValue: UInt32(xwaylandProtocolTakeFocus))
    public static let ping = XwaylandProtocols(rawValue: UInt32(xwaylandProtocolPing))
    public static let syncRequest = XwaylandProtocols(rawValue: UInt32(xwaylandProtocolSyncRequest))
}

public struct XwaylandWindowType: OptionSet, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let normal = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeNormal))
    public static let dialog = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeDialog))
    public static let utility = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeUtility))
    public static let toolbar = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeToolbar))
    public static let splash = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeSplash))
    public static let menu = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeMenu))
    public static let dropdownMenu = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeDropdownMenu))
    public static let popupMenu = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypePopupMenu))
    public static let tooltip = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeTooltip))
    public static let notification = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeNotification))
    public static let dock = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeDock))
    public static let desktop = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeDesktop))
    public static let dragAndDrop = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeDnd))
    public static let combo = XwaylandWindowType(rawValue: UInt64(xwaylandWindowTypeCombo))

    public var wantsOverrideRedirectFocus: Bool {
        !intersection(XwaylandWindowType([.popupMenu, .dropdownMenu, .combo, .dragAndDrop])).isEmpty
    }
}

public struct XwaylandNetState: OptionSet, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let fullscreen = XwaylandNetState(rawValue: UInt64(xwaylandNetStateFullscreen))
    public static let maximizedVert = XwaylandNetState(rawValue: UInt64(xwaylandNetStateMaximizedVert))
    public static let maximizedHorz = XwaylandNetState(rawValue: UInt64(xwaylandNetStateMaximizedHorz))
    public static let hidden = XwaylandNetState(rawValue: UInt64(xwaylandNetStateHidden))
    public static let above = XwaylandNetState(rawValue: UInt64(xwaylandNetStateAbove))
    public static let below = XwaylandNetState(rawValue: UInt64(xwaylandNetStateBelow))
    public static let demandsAttention = XwaylandNetState(rawValue: UInt64(xwaylandNetStateDemandsAttention))
    public static let modal = XwaylandNetState(rawValue: UInt64(xwaylandNetStateModal))
    public static let skipTaskbar = XwaylandNetState(rawValue: UInt64(xwaylandNetStateSkipTaskbar))
    public static let skipPager = XwaylandNetState(rawValue: UInt64(xwaylandNetStateSkipPager))
    public static let sticky = XwaylandNetState(rawValue: UInt64(xwaylandNetStateSticky))
    public static let focused = XwaylandNetState(rawValue: UInt64(xwaylandNetStateFocused))

    public var maximized: Bool {
        contains(.maximizedVert) || contains(.maximizedHorz)
    }
}

public enum XwaylandFocusModel: UInt32, Sendable, Equatable {
    case noInput
    case passive
    case locallyActive
    case globallyActive

    public init(input: Bool, takeFocus: Bool) {
        switch (input, takeFocus) {
        case (true, false): self = .passive
        case (true, true): self = .locallyActive
        case (false, true): self = .globallyActive
        case (false, false): self = .noInput
        }
    }
}

public struct XwaylandHints: Sendable, Equatable {
    public var input: Bool
    public var urgent: Bool
    public var decorationsOff: Bool

    public init(input: Bool = true, urgent: Bool = false, decorationsOff: Bool = false) {
        self.input = input
        self.urgent = urgent
        self.decorationsOff = decorationsOff
    }

    public func focusModel(protocols: XwaylandProtocols) -> XwaylandFocusModel {
        XwaylandFocusModel(input: input, takeFocus: protocols.contains(.takeFocus))
    }
}

public struct XwaylandWindowMetadata: Sendable, Equatable {
    public var x11WindowID: UInt64
    public var transientForX11WindowID: UInt64?
    public var windowTypes: XwaylandWindowType
    public var netState: XwaylandNetState
    public var protocols: XwaylandProtocols
    public var processID: UInt32?
    public var userTime: UInt32
    public var overrideRedirect: Bool
    public var hints: XwaylandHints

    /// Field-wise init: the Swift-native XWM constructs this directly from the XCB
    /// event/property data (no wire ABI round-trip).
    public init(
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

public struct XwaylandStateRequest: Sendable, Equatable {
    public var windowID: UInt64
    public var action: UInt32
    public var states: XwaylandNetState
    public var sourceIndication: UInt32

    /// Field-wise init: the Swift-native XWM constructs this directly from the XCB
    /// event/property data (no wire ABI round-trip).
    public init(windowID: UInt64, action: UInt32, stateMask: UInt64, sourceIndication: UInt32) {
        self.windowID = windowID
        self.action = action
        self.states = XwaylandNetState(rawValue: stateMask)
        self.sourceIndication = sourceIndication
    }
}

public struct XwaylandStatePlan: Sendable, Equatable {
    public var handled: Bool = false
    public var requestConfigure: Bool = false
    public var activate: Bool = false
    public var raise: Bool = false
    public var requestedFullscreen: Bool = false
    public var requestedMaximized: Bool = false
    public var netState: XwaylandNetState = []

    public init(
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

public struct XwaylandFocusPlan: Sendable, Equatable {
    public var actions: UInt32 = 0
    public var activeX11Window: UInt64 = 0
    public var previousX11Window: UInt64 = 0
    public var focusedX11Window: UInt64 = 0
    public var deniedSyncState: UInt64 = 0

    public init(
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

public struct XwaylandClosePlan: Sendable, Equatable {
    public var action: UInt32 = UInt32(xwaylandCloseNone)

    public init(action: UInt32 = UInt32(xwaylandCloseNone)) {
        self.action = action
    }
}
