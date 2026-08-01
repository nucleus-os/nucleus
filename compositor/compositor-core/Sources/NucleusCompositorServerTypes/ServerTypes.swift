import Swift

package struct WlSurfaceID: Hashable, Comparable, Sendable {
    package let rawValue: Swift.UInt32

    package init(_ rawValue: Swift.UInt32) {
        precondition(rawValue != 0, "zero is not a valid compositor surface identity")
        self.rawValue = rawValue
    }

    package static func < (lhs: Self, rhs: Self) -> Swift.Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package enum WireInteractionMode: Swift.UInt32, Swift.Sendable {
    case move = 1
    case resize = 2
}

package enum WireEventDispatchAction: Swift.UInt32, Swift.Sendable {
    case route = 0
    case consumed = 1
    case exitRequested = 2
    case switchVt = 3
    case delivered = 4
}

package enum WireEventKind: Swift.UInt32, Swift.Sendable {
    case nullEvent = 0
    case leftMouseDown = 1
    case leftMouseUp = 2
    case rightMouseDown = 3
    case rightMouseUp = 4
    case mouseMoved = 5
    case leftMouseDragged = 6
    case rightMouseDragged = 7
    case keyDown = 8
    case keyUp = 9
    case flagsChanged = 10
    case scrollWheel = 11
    case tabletPointer = 12
    case tabletProximity = 13
    case otherMouseDown = 14
    case otherMouseUp = 15
    case otherMouseDragged = 16
    case tapDisabledByTimeout = 17
    case tapDisabledByUserInput = 18
    case touchDown = 19
    case touchUp = 20
    case touchMotion = 21
    case touchCancel = 22
    case touchFrame = 23
}

package let displayChangeEnabled: Swift.UInt64 = 1
package let displayChangePrimary: Swift.UInt64 = 2
package let displayChangeLogicalX: Swift.UInt64 = 4
package let displayChangeLogicalY: Swift.UInt64 = 8
package let displayChangeLogicalWidth: Swift.UInt64 = 16
package let displayChangeLogicalHeight: Swift.UInt64 = 32
package let displayChangeScale: Swift.UInt64 = 64
package let displayChangeFractionalScale: Swift.UInt64 = 128
package let displayChangeMode: Swift.UInt64 = 256
package let eventDispatchRoute: Swift.UInt32 = 0
package let eventDispatchConsumed: Swift.UInt32 = 1
package let eventDispatchExitRequested: Swift.UInt32 = 2
package let eventDispatchSwitchVt: Swift.UInt32 = 3
package let eventDispatchDelivered: Swift.UInt32 = 4
package let interactionModeMove: Swift.UInt32 = 1
package let interactionModeResize: Swift.UInt32 = 2
package let xwaylandProtocolDeleteWindow: Swift.UInt32 = 1
package let xwaylandProtocolTakeFocus: Swift.UInt32 = 2
package let xwaylandProtocolPing: Swift.UInt32 = 4
package let xwaylandProtocolSyncRequest: Swift.UInt32 = 8
package let xwaylandWindowTypeNormal: Swift.UInt64 = 1
package let xwaylandWindowTypeDialog: Swift.UInt64 = 2
package let xwaylandWindowTypeUtility: Swift.UInt64 = 4
package let xwaylandWindowTypeToolbar: Swift.UInt64 = 8
package let xwaylandWindowTypeSplash: Swift.UInt64 = 16
package let xwaylandWindowTypeMenu: Swift.UInt64 = 32
package let xwaylandWindowTypeDropdownMenu: Swift.UInt64 = 64
package let xwaylandWindowTypePopupMenu: Swift.UInt64 = 128
package let xwaylandWindowTypeTooltip: Swift.UInt64 = 256
package let xwaylandWindowTypeNotification: Swift.UInt64 = 512
package let xwaylandWindowTypeDock: Swift.UInt64 = 1024
package let xwaylandWindowTypeDesktop: Swift.UInt64 = 2048
package let xwaylandWindowTypeDnd: Swift.UInt64 = 4096
package let xwaylandWindowTypeCombo: Swift.UInt64 = 8192
package let xwaylandNetStateFullscreen: Swift.UInt64 = 1
package let xwaylandNetStateMaximizedVert: Swift.UInt64 = 2
package let xwaylandNetStateMaximizedHorz: Swift.UInt64 = 4
package let xwaylandNetStateHidden: Swift.UInt64 = 8
package let xwaylandNetStateAbove: Swift.UInt64 = 16
package let xwaylandNetStateBelow: Swift.UInt64 = 32
package let xwaylandNetStateDemandsAttention: Swift.UInt64 = 64
package let xwaylandNetStateModal: Swift.UInt64 = 128
package let xwaylandNetStateSkipTaskbar: Swift.UInt64 = 256
package let xwaylandNetStateSkipPager: Swift.UInt64 = 512
package let xwaylandNetStateSticky: Swift.UInt64 = 1024
package let xwaylandNetStateFocused: Swift.UInt64 = 2048
package let xwaylandFocusSetInput: Swift.UInt32 = 1
package let xwaylandFocusTakeFocus: Swift.UInt32 = 2
package let xwaylandFocusClear: Swift.UInt32 = 4
package let xwaylandFocusDenied: Swift.UInt32 = 8
package let xwaylandCloseNone: Swift.UInt32 = 0
package let xwaylandCloseDeleteWindow: Swift.UInt32 = 1
package let xwaylandCloseDestroy: Swift.UInt32 = 2

package struct WireLogicalRect: Swift.Equatable, Swift.Sendable {
    package var x: Swift.Double
    package var y: Swift.Double
    package var width: Swift.Double
    package var height: Swift.Double
    package init(
        x: Swift.Double = 0, y: Swift.Double = 0, width: Swift.Double = 0, height: Swift.Double = 0
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct WireRenderRect: Swift.Equatable, Swift.Sendable {
    package var x: Swift.Double
    package var y: Swift.Double
    package var w: Swift.Double
    package var h: Swift.Double
    package init(x: Swift.Double = 0, y: Swift.Double = 0, w: Swift.Double = 0, h: Swift.Double = 0)
    {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

package struct WirePixelSize: Swift.Equatable, Swift.Sendable {
    package var width: Swift.UInt32
    package var height: Swift.UInt32
    package init(width: Swift.UInt32 = Swift.UInt32(), height: Swift.UInt32 = Swift.UInt32()) {
        self.width = width
        self.height = height
    }
}

package struct WirePhysicalRect: Swift.Equatable, Swift.Sendable {
    package var x: Swift.Int32
    package var y: Swift.Int32
    package var width: Swift.UInt32
    package var height: Swift.UInt32
    package init(
        x: Swift.Int32 = Swift.Int32(), y: Swift.Int32 = Swift.Int32(),
        width: Swift.UInt32 = Swift.UInt32(), height: Swift.UInt32 = Swift.UInt32()
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct WireUsableArea: Swift.Equatable, Swift.Sendable {
    package var x: Swift.Int32
    package var y: Swift.Int32
    package var w: Swift.Int32
    package var h: Swift.Int32
    package init(
        x: Swift.Int32 = Swift.Int32(), y: Swift.Int32 = Swift.Int32(),
        w: Swift.Int32 = Swift.Int32(), h: Swift.Int32 = Swift.Int32()
    ) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

package struct WireDisplayMode: Swift.Equatable, Swift.Sendable {
    package var pixelWidth: Swift.UInt32
    package var pixelHeight: Swift.UInt32
    package var refreshMhz: Swift.Int32
    package init(
        pixelWidth: Swift.UInt32 = Swift.UInt32(), pixelHeight: Swift.UInt32 = Swift.UInt32(),
        refreshMhz: Swift.Int32 = Swift.Int32()
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshMhz = refreshMhz
    }
}

package struct WireDisplayConfiguration: Swift.Equatable, Swift.Sendable {
    package var enabled: Swift.Bool
    package var primary: Swift.Bool
    package var reserved0: Swift.UInt16
    package var scale: Swift.UInt32
    package var logicalX: Swift.Double
    package var logicalY: Swift.Double
    package var logicalWidth: Swift.Double
    package var logicalHeight: Swift.Double
    package var fractionalScale: Swift.Double
    package var mode: NucleusCompositorServerTypes.WireDisplayMode
    package init(
        enabled: Swift.Bool = false, primary: Swift.Bool = false,
        reserved0: Swift.UInt16 = Swift.UInt16(), scale: Swift.UInt32 = Swift.UInt32(),
        logicalX: Swift.Double = 0, logicalY: Swift.Double = 0, logicalWidth: Swift.Double = 0,
        logicalHeight: Swift.Double = 0, fractionalScale: Swift.Double = 0,
        mode: NucleusCompositorServerTypes.WireDisplayMode =
            NucleusCompositorServerTypes.WireDisplayMode()
    ) {
        self.enabled = enabled
        self.primary = primary
        self.reserved0 = reserved0
        self.scale = scale
        self.logicalX = logicalX
        self.logicalY = logicalY
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.fractionalScale = fractionalScale
        self.mode = mode
    }
}

package struct WireDisplayConfigurationChanges: Swift.Equatable, Swift.Sendable {
    package var mask: Swift.UInt64
    package var enabled: Swift.Bool
    package var primary: Swift.Bool
    package var reserved0: Swift.UInt16
    package var scale: Swift.UInt32
    package var logicalX: Swift.Double
    package var logicalY: Swift.Double
    package var logicalWidth: Swift.Double
    package var logicalHeight: Swift.Double
    package var fractionalScale: Swift.Double
    package var mode: NucleusCompositorServerTypes.WireDisplayMode
    package init(
        mask: Swift.UInt64 = Swift.UInt64(), enabled: Swift.Bool = false,
        primary: Swift.Bool = false, reserved0: Swift.UInt16 = Swift.UInt16(),
        scale: Swift.UInt32 = Swift.UInt32(), logicalX: Swift.Double = 0,
        logicalY: Swift.Double = 0, logicalWidth: Swift.Double = 0, logicalHeight: Swift.Double = 0,
        fractionalScale: Swift.Double = 0,
        mode: NucleusCompositorServerTypes.WireDisplayMode =
            NucleusCompositorServerTypes.WireDisplayMode()
    ) {
        self.mask = mask
        self.enabled = enabled
        self.primary = primary
        self.reserved0 = reserved0
        self.scale = scale
        self.logicalX = logicalX
        self.logicalY = logicalY
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.fractionalScale = fractionalScale
        self.mode = mode
    }
}

package struct WireWindowRect: Swift.Equatable, Swift.Sendable {
    package var x: Swift.Double
    package var y: Swift.Double
    package var width: Swift.UInt32
    package var height: Swift.UInt32
    package init(
        x: Swift.Double = 0, y: Swift.Double = 0, width: Swift.UInt32 = Swift.UInt32(),
        height: Swift.UInt32 = Swift.UInt32()
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct WireChromeInsets: Swift.Equatable, Swift.Sendable {
    package var top: Swift.Double
    package var left: Swift.Double
    package var bottom: Swift.Double
    package var right: Swift.Double
    package init(
        top: Swift.Double = 0, left: Swift.Double = 0, bottom: Swift.Double = 0,
        right: Swift.Double = 0
    ) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

package struct WireRequestedSpecialMode: Swift.Equatable, Swift.Sendable {
    package var activeMaximized: Swift.Bool
    package var activeFullscreen: Swift.Bool
    package var willSpecial: Swift.Bool
    package var reserved0: Swift.UInt8
    package init(
        activeMaximized: Swift.Bool = false, activeFullscreen: Swift.Bool = false,
        willSpecial: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8()
    ) {
        self.activeMaximized = activeMaximized
        self.activeFullscreen = activeFullscreen
        self.willSpecial = willSpecial
        self.reserved0 = reserved0
    }
}

package struct WireLayoutRects: Swift.Equatable, Swift.Sendable {
    package var fullscreen: NucleusCompositorServerTypes.WireWindowRect
    package var maximized: NucleusCompositorServerTypes.WireWindowRect
    package var defaultRect: NucleusCompositorServerTypes.WireWindowRect
    package init(
        fullscreen: NucleusCompositorServerTypes.WireWindowRect =
            NucleusCompositorServerTypes.WireWindowRect(),
        maximized: NucleusCompositorServerTypes.WireWindowRect =
            NucleusCompositorServerTypes.WireWindowRect(),
        defaultRect: NucleusCompositorServerTypes.WireWindowRect =
            NucleusCompositorServerTypes.WireWindowRect()
    ) {
        self.fullscreen = fullscreen
        self.maximized = maximized
        self.defaultRect = defaultRect
    }
}

package struct WireWindowPolicySnapshot: Swift.Equatable, Swift.Sendable {
    package var policyOutputId: Swift.UInt64
    package var requestedFullscreenOutputId: Swift.UInt64
    package var requestedMaximizedOutputId: Swift.UInt64
    package var requestedSpecial: NucleusCompositorServerTypes.WireRequestedSpecialMode
    package var activeMaximized: Swift.Bool
    package var activeFullscreen: Swift.Bool
    package var managedAppWindow: Swift.Bool
    package var wantsKeyboardFocus: Swift.Bool
    package var reserved0: Swift.UInt32
    package init(
        policyOutputId: Swift.UInt64 = Swift.UInt64(),
        requestedFullscreenOutputId: Swift.UInt64 = Swift.UInt64(),
        requestedMaximizedOutputId: Swift.UInt64 = Swift.UInt64(),
        requestedSpecial: NucleusCompositorServerTypes.WireRequestedSpecialMode =
            NucleusCompositorServerTypes.WireRequestedSpecialMode(),
        activeMaximized: Swift.Bool = false, activeFullscreen: Swift.Bool = false,
        managedAppWindow: Swift.Bool = false, wantsKeyboardFocus: Swift.Bool = false,
        reserved0: Swift.UInt32 = Swift.UInt32()
    ) {
        self.policyOutputId = policyOutputId
        self.requestedFullscreenOutputId = requestedFullscreenOutputId
        self.requestedMaximizedOutputId = requestedMaximizedOutputId
        self.requestedSpecial = requestedSpecial
        self.activeMaximized = activeMaximized
        self.activeFullscreen = activeFullscreen
        self.managedAppWindow = managedAppWindow
        self.wantsKeyboardFocus = wantsKeyboardFocus
        self.reserved0 = reserved0
    }
}

package struct WireWindowRenderOrderEntry: Swift.Equatable, Swift.Sendable {
    package var windowId: Swift.UInt64
    package var policy: NucleusCompositorServerTypes.WireWindowPolicySnapshot
    package init(
        windowId: Swift.UInt64 = Swift.UInt64(),
        policy: NucleusCompositorServerTypes.WireWindowPolicySnapshot =
            NucleusCompositorServerTypes.WireWindowPolicySnapshot()
    ) {
        self.windowId = windowId
        self.policy = policy
    }
}

package struct WireOutputLayoutSnapshot: Swift.Equatable, Swift.Sendable {
    package var fullscreenRect: NucleusCompositorServerTypes.WireWindowRect
    package var maximizedRect: NucleusCompositorServerTypes.WireWindowRect
    package var defaultRect: NucleusCompositorServerTypes.WireWindowRect
    package init(
        fullscreenRect: NucleusCompositorServerTypes.WireWindowRect =
            NucleusCompositorServerTypes.WireWindowRect(),
        maximizedRect: NucleusCompositorServerTypes.WireWindowRect =
            NucleusCompositorServerTypes.WireWindowRect(),
        defaultRect: NucleusCompositorServerTypes.WireWindowRect =
            NucleusCompositorServerTypes.WireWindowRect()
    ) {
        self.fullscreenRect = fullscreenRect
        self.maximizedRect = maximizedRect
        self.defaultRect = defaultRect
    }
}

package struct WireEventRecord: Swift.Equatable, Swift.Sendable {
    package var _kind: Swift.UInt32
    package var flags: Swift.UInt64
    package var timestampNs: Swift.UInt64
    package var x: Swift.Double
    package var y: Swift.Double
    package var data0: Swift.UInt64
    package var data1: Swift.UInt64
    package var data2: Swift.UInt64
    package var data3: Swift.UInt64
    package init(
        kind: WireEventKind = .nullEvent, flags: Swift.UInt64 = Swift.UInt64(),
        timestampNs: Swift.UInt64 = Swift.UInt64(), x: Swift.Double = 0, y: Swift.Double = 0,
        data0: Swift.UInt64 = Swift.UInt64(), data1: Swift.UInt64 = Swift.UInt64(),
        data2: Swift.UInt64 = Swift.UInt64(), data3: Swift.UInt64 = Swift.UInt64()
    ) {
        self._kind = kind.rawValue
        self.flags = flags
        self.timestampNs = timestampNs
        self.x = x
        self.y = y
        self.data0 = data0
        self.data1 = data1
        self.data2 = data2
        self.data3 = data3
    }
    package var kind: WireEventKind {
        get { WireEventKind(rawValue: _kind)! }
        set { _kind = newValue.rawValue }
    }
}

package struct WirePointerBounds: Swift.Equatable, Swift.Sendable {
    package var minX: Swift.Double
    package var minY: Swift.Double
    package var maxX: Swift.Double
    package var maxY: Swift.Double
    package init(
        minX: Swift.Double = 0, minY: Swift.Double = 0, maxX: Swift.Double = 0,
        maxY: Swift.Double = 0
    ) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

package struct WireEventStateSnapshot: Swift.Equatable, Swift.Sendable {
    package var cursorX: Swift.Double
    package var cursorY: Swift.Double
    package var flags: Swift.UInt64
    package var leftButtonDown: Swift.Bool
    package var rightButtonDown: Swift.Bool
    package var otherButtonCount: Swift.UInt8
    package var reserved0: Swift.UInt8
    package init(
        cursorX: Swift.Double = 0, cursorY: Swift.Double = 0, flags: Swift.UInt64 = Swift.UInt64(),
        leftButtonDown: Swift.Bool = false, rightButtonDown: Swift.Bool = false,
        otherButtonCount: Swift.UInt8 = Swift.UInt8(), reserved0: Swift.UInt8 = Swift.UInt8()
    ) {
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.flags = flags
        self.leftButtonDown = leftButtonDown
        self.rightButtonDown = rightButtonDown
        self.otherButtonCount = otherButtonCount
        self.reserved0 = reserved0
    }
}

package struct WireEventStateChange: Swift.Equatable, Swift.Sendable {
    package var cursorMoved: Swift.Bool
    package var buttonChanged: Swift.Bool
    package var flagsChanged: Swift.Bool
    package var reserved0: Swift.UInt8
    package init(
        cursorMoved: Swift.Bool = false, buttonChanged: Swift.Bool = false,
        flagsChanged: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8()
    ) {
        self.cursorMoved = cursorMoved
        self.buttonChanged = buttonChanged
        self.flagsChanged = flagsChanged
        self.reserved0 = reserved0
    }
}

package struct WireEventDispatchDecision: Swift.Equatable, Swift.Sendable {
    package var _action: Swift.UInt32
    package var dispatchValue: Swift.Int32
    package var event: NucleusCompositorServerTypes.WireEventRecord
    package var state: NucleusCompositorServerTypes.WireEventStateSnapshot
    package var change: NucleusCompositorServerTypes.WireEventStateChange
    package init(
        action: WireEventDispatchAction = .route, dispatchValue: Swift.Int32 = Swift.Int32(),
        event: NucleusCompositorServerTypes.WireEventRecord =
            NucleusCompositorServerTypes.WireEventRecord(),
        state: NucleusCompositorServerTypes.WireEventStateSnapshot =
            NucleusCompositorServerTypes.WireEventStateSnapshot(),
        change: NucleusCompositorServerTypes.WireEventStateChange =
            NucleusCompositorServerTypes.WireEventStateChange()
    ) {
        self._action = action.rawValue
        self.dispatchValue = dispatchValue
        self.event = event
        self.state = state
        self.change = change
    }
    package var action: WireEventDispatchAction {
        get { WireEventDispatchAction(rawValue: _action)! }
        set { _action = newValue.rawValue }
    }
}

package struct WireSeatFocusSnapshot: Swift.Equatable, Swift.Sendable {
    package var pointerSurfaceId: Swift.UInt64
    package var keyboardSurfaceId: Swift.UInt64
    package var buttonCount: Swift.UInt32
    package var lastPointerButtonSerial: Swift.UInt32
    package var lastPointerButtonSurfaceId: Swift.UInt64
    package init(
        pointerSurfaceId: Swift.UInt64 = Swift.UInt64(),
        keyboardSurfaceId: Swift.UInt64 = Swift.UInt64(),
        buttonCount: Swift.UInt32 = Swift.UInt32(),
        lastPointerButtonSerial: Swift.UInt32 = Swift.UInt32(),
        lastPointerButtonSurfaceId: Swift.UInt64 = Swift.UInt64()
    ) {
        self.pointerSurfaceId = pointerSurfaceId
        self.keyboardSurfaceId = keyboardSurfaceId
        self.buttonCount = buttonCount
        self.lastPointerButtonSerial = lastPointerButtonSerial
        self.lastPointerButtonSurfaceId = lastPointerButtonSurfaceId
    }
}

package struct WireResizeEdges: Swift.Equatable, Swift.Sendable {
    package var top: Swift.Bool
    package var bottom: Swift.Bool
    package var left: Swift.Bool
    package var right: Swift.Bool
    package init(
        top: Swift.Bool = false, bottom: Swift.Bool = false, left: Swift.Bool = false,
        right: Swift.Bool = false
    ) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
}

package struct WireInteractionGrabUpdate: Swift.Equatable, Swift.Sendable {
    package var hasUpdate: Swift.Bool
    package var needsResizeConfigure: Swift.Bool
    package var reserved0: Swift.UInt16
    package var _mode: Swift.UInt32
    package var windowId: Swift.UInt64
    package var rect: NucleusCompositorServerTypes.WireWindowRect
    package init(
        hasUpdate: Swift.Bool = false, needsResizeConfigure: Swift.Bool = false,
        reserved0: Swift.UInt16 = Swift.UInt16(), mode: WireInteractionMode = .move,
        windowId: Swift.UInt64 = Swift.UInt64(),
        rect: NucleusCompositorServerTypes.WireWindowRect =
            NucleusCompositorServerTypes.WireWindowRect()
    ) {
        self.hasUpdate = hasUpdate
        self.needsResizeConfigure = needsResizeConfigure
        self.reserved0 = reserved0
        self._mode = mode.rawValue
        self.windowId = windowId
        self.rect = rect
    }
    package var mode: WireInteractionMode {
        get { WireInteractionMode(rawValue: _mode)! }
        set { _mode = newValue.rawValue }
    }
}

package struct WireOutputMigrationResult: Swift.Equatable, Swift.Sendable {
    package var managed: Swift.Bool
    package var changed: Swift.Bool
    package var specialChanged: Swift.Bool
    package var reserved0: Swift.UInt8
    package init(
        managed: Swift.Bool = false, changed: Swift.Bool = false,
        specialChanged: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8()
    ) {
        self.managed = managed
        self.changed = changed
        self.specialChanged = specialChanged
        self.reserved0 = reserved0
    }
}

package struct WirePopupPositioner: Swift.Equatable, Swift.Sendable {
    package var sizeW: Swift.Int32
    package var sizeH: Swift.Int32
    package var anchorRectX: Swift.Int32
    package var anchorRectY: Swift.Int32
    package var anchorRectW: Swift.Int32
    package var anchorRectH: Swift.Int32
    package var anchor: Swift.UInt32
    package var gravity: Swift.UInt32
    package var constraintAdjustment: Swift.UInt32
    package var reserved0: Swift.UInt32
    package var offsetX: Swift.Int32
    package var offsetY: Swift.Int32
    package init(
        sizeW: Swift.Int32 = Swift.Int32(), sizeH: Swift.Int32 = Swift.Int32(),
        anchorRectX: Swift.Int32 = Swift.Int32(), anchorRectY: Swift.Int32 = Swift.Int32(),
        anchorRectW: Swift.Int32 = Swift.Int32(), anchorRectH: Swift.Int32 = Swift.Int32(),
        anchor: Swift.UInt32 = Swift.UInt32(), gravity: Swift.UInt32 = Swift.UInt32(),
        constraintAdjustment: Swift.UInt32 = Swift.UInt32(),
        reserved0: Swift.UInt32 = Swift.UInt32(), offsetX: Swift.Int32 = Swift.Int32(),
        offsetY: Swift.Int32 = Swift.Int32()
    ) {
        self.sizeW = sizeW
        self.sizeH = sizeH
        self.anchorRectX = anchorRectX
        self.anchorRectY = anchorRectY
        self.anchorRectW = anchorRectW
        self.anchorRectH = anchorRectH
        self.anchor = anchor
        self.gravity = gravity
        self.constraintAdjustment = constraintAdjustment
        self.reserved0 = reserved0
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

package struct WirePopupResolvedRect: Swift.Equatable, Swift.Sendable {
    package var x: Swift.Int32
    package var y: Swift.Int32
    package var w: Swift.Int32
    package var h: Swift.Int32
    package init(
        x: Swift.Int32 = Swift.Int32(), y: Swift.Int32 = Swift.Int32(),
        w: Swift.Int32 = Swift.Int32(), h: Swift.Int32 = Swift.Int32()
    ) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

package struct WireBackdropLayerInput: Swift.Equatable, Swift.Sendable {
    package var layerId: Swift.UInt64
    package var frameX: Swift.Double
    package var frameY: Swift.Double
    package var frameWidth: Swift.Double
    package var frameHeight: Swift.Double
    package var isOpaqueOccluder: Swift.Bool
    package var reserved0: Swift.UInt8
    package var reserved1: Swift.UInt16
    package var reserved2: Swift.UInt32
    package var producerGroupId: Swift.UInt64
    package init(
        layerId: Swift.UInt64 = Swift.UInt64(), frameX: Swift.Double = 0, frameY: Swift.Double = 0,
        frameWidth: Swift.Double = 0, frameHeight: Swift.Double = 0,
        isOpaqueOccluder: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8(),
        reserved1: Swift.UInt16 = Swift.UInt16(), reserved2: Swift.UInt32 = Swift.UInt32(),
        producerGroupId: Swift.UInt64 = Swift.UInt64()
    ) {
        self.layerId = layerId
        self.frameX = frameX
        self.frameY = frameY
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.isOpaqueOccluder = isOpaqueOccluder
        self.reserved0 = reserved0
        self.reserved1 = reserved1
        self.reserved2 = reserved2
        self.producerGroupId = producerGroupId
    }
}

package struct WireBackdropAccessibility: Swift.Equatable, Swift.Sendable {
    package var reduceTransparency: Swift.Bool
    package var systemAppearance: Swift.UInt8
    package var increaseContrast: Swift.Bool
    package var reserved1: Swift.UInt8
    package init(
        reduceTransparency: Swift.Bool = false, systemAppearance: Swift.UInt8 = Swift.UInt8(),
        increaseContrast: Swift.Bool = false, reserved1: Swift.UInt8 = Swift.UInt8()
    ) {
        self.reduceTransparency = reduceTransparency
        self.systemAppearance = systemAppearance
        self.increaseContrast = increaseContrast
        self.reserved1 = reserved1
    }
}

package struct WireBackdropMaterialInput: Swift.Equatable, Swift.Sendable {
    package var layerId: Swift.UInt64
    package var material: Swift.UInt32
    package var requestedState: Swift.UInt32
    package var appearance: Swift.UInt8
    package var isEmphasized: Swift.Bool
    package var hasOwningWindow: Swift.Bool
    package var reserved0: Swift.UInt8
    package var owningWindowId: Swift.UInt64
    package var tintR: Swift.Float
    package var tintG: Swift.Float
    package var tintB: Swift.Float
    package var tintA: Swift.Float
    package var opacity: Swift.Float
    package init(
        layerId: Swift.UInt64 = Swift.UInt64(), material: Swift.UInt32 = Swift.UInt32(),
        requestedState: Swift.UInt32 = Swift.UInt32(), appearance: Swift.UInt8 = Swift.UInt8(),
        isEmphasized: Swift.Bool = false, hasOwningWindow: Swift.Bool = false,
        reserved0: Swift.UInt8 = Swift.UInt8(), owningWindowId: Swift.UInt64 = Swift.UInt64(),
        tintR: Swift.Float = 0, tintG: Swift.Float = 0, tintB: Swift.Float = 0,
        tintA: Swift.Float = 0, opacity: Swift.Float = 0
    ) {
        self.layerId = layerId
        self.material = material
        self.requestedState = requestedState
        self.appearance = appearance
        self.isEmphasized = isEmphasized
        self.hasOwningWindow = hasOwningWindow
        self.reserved0 = reserved0
        self.owningWindowId = owningWindowId
        self.tintR = tintR
        self.tintG = tintG
        self.tintB = tintB
        self.tintA = tintA
        self.opacity = opacity
    }
}

package struct WireBackdropMaterialSpec: Swift.Equatable, Swift.Sendable {
    package var layerId: Swift.UInt64
    package var enabled: Swift.Bool
    package var passes: Swift.UInt8
    package var foregroundVariant: Swift.UInt8
    package var resolvedAppearance: Swift.UInt8
    package var resolvedState: Swift.UInt32
    package var needsFrame: Swift.Bool
    package var reserved0: Swift.UInt8
    package var reserved1: Swift.UInt16
    package var offset: Swift.Float
    package var saturation: Swift.Float
    package var tintR: Swift.Float
    package var tintG: Swift.Float
    package var tintB: Swift.Float
    package var tintA: Swift.Float
    package var tintBlend: Swift.Float
    package var noise: Swift.Float
    package var alpha: Swift.Float
    package var solidFallbackR: Swift.Float
    package var solidFallbackG: Swift.Float
    package var solidFallbackB: Swift.Float
    package var solidFallbackA: Swift.Float
    package init(
        layerId: Swift.UInt64 = Swift.UInt64(), enabled: Swift.Bool = false,
        passes: Swift.UInt8 = Swift.UInt8(), foregroundVariant: Swift.UInt8 = Swift.UInt8(),
        resolvedAppearance: Swift.UInt8 = Swift.UInt8(),
        resolvedState: Swift.UInt32 = Swift.UInt32(), needsFrame: Swift.Bool = false,
        reserved0: Swift.UInt8 = Swift.UInt8(), reserved1: Swift.UInt16 = Swift.UInt16(),
        offset: Swift.Float = 0, saturation: Swift.Float = 0, tintR: Swift.Float = 0,
        tintG: Swift.Float = 0, tintB: Swift.Float = 0, tintA: Swift.Float = 0,
        tintBlend: Swift.Float = 0, noise: Swift.Float = 0, alpha: Swift.Float = 0,
        solidFallbackR: Swift.Float = 0, solidFallbackG: Swift.Float = 0,
        solidFallbackB: Swift.Float = 0, solidFallbackA: Swift.Float = 0
    ) {
        self.layerId = layerId
        self.enabled = enabled
        self.passes = passes
        self.foregroundVariant = foregroundVariant
        self.resolvedAppearance = resolvedAppearance
        self.resolvedState = resolvedState
        self.needsFrame = needsFrame
        self.reserved0 = reserved0
        self.reserved1 = reserved1
        self.offset = offset
        self.saturation = saturation
        self.tintR = tintR
        self.tintG = tintG
        self.tintB = tintB
        self.tintA = tintA
        self.tintBlend = tintBlend
        self.noise = noise
        self.alpha = alpha
        self.solidFallbackR = solidFallbackR
        self.solidFallbackG = solidFallbackG
        self.solidFallbackB = solidFallbackB
        self.solidFallbackA = solidFallbackA
    }
}

package struct WireBackdropDraw: Swift.Equatable, Swift.Sendable {
    package var layerId: Swift.UInt64
    package var regionX: Swift.Double
    package var regionY: Swift.Double
    package var regionWidth: Swift.Double
    package var regionHeight: Swift.Double
    package var groupId: Swift.UInt64
    package var resolvedState: Swift.UInt32
    package var resolvedAppearance: Swift.UInt8
    package var reserved0: Swift.UInt8
    package var reserved1: Swift.UInt8
    package var reserved2: Swift.UInt8
    package init(
        layerId: Swift.UInt64 = Swift.UInt64(), regionX: Swift.Double = 0,
        regionY: Swift.Double = 0, regionWidth: Swift.Double = 0, regionHeight: Swift.Double = 0,
        groupId: Swift.UInt64 = Swift.UInt64(), resolvedState: Swift.UInt32 = Swift.UInt32(),
        resolvedAppearance: Swift.UInt8 = Swift.UInt8(), reserved0: Swift.UInt8 = Swift.UInt8(),
        reserved1: Swift.UInt8 = Swift.UInt8(), reserved2: Swift.UInt8 = Swift.UInt8()
    ) {
        self.layerId = layerId
        self.regionX = regionX
        self.regionY = regionY
        self.regionWidth = regionWidth
        self.regionHeight = regionHeight
        self.groupId = groupId
        self.resolvedState = resolvedState
        self.resolvedAppearance = resolvedAppearance
        self.reserved0 = reserved0
        self.reserved1 = reserved1
        self.reserved2 = reserved2
    }
}
