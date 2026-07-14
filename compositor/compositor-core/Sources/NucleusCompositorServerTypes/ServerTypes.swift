import Swift

public enum WireInteractionMode: Swift.UInt32, Swift.Sendable {
  case move = 1
  case resize = 2
}

public enum WireEventDispatchAction: Swift.UInt32, Swift.Sendable {
  case route = 0
  case consumed = 1
  case exitRequested = 2
  case switchVt = 3
  case delivered = 4
}

public enum WireEventKind: Swift.UInt32, Swift.Sendable {
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

public let displayChangeEnabled: Swift.UInt64 = 1
public let displayChangePrimary: Swift.UInt64 = 2
public let displayChangeLogicalX: Swift.UInt64 = 4
public let displayChangeLogicalY: Swift.UInt64 = 8
public let displayChangeLogicalWidth: Swift.UInt64 = 16
public let displayChangeLogicalHeight: Swift.UInt64 = 32
public let displayChangeScale: Swift.UInt64 = 64
public let displayChangeFractionalScale: Swift.UInt64 = 128
public let displayChangeMode: Swift.UInt64 = 256
public let eventDispatchRoute: Swift.UInt32 = 0
public let eventDispatchConsumed: Swift.UInt32 = 1
public let eventDispatchExitRequested: Swift.UInt32 = 2
public let eventDispatchSwitchVt: Swift.UInt32 = 3
public let eventDispatchDelivered: Swift.UInt32 = 4
public let interactionModeMove: Swift.UInt32 = 1
public let interactionModeResize: Swift.UInt32 = 2
public let xwaylandProtocolDeleteWindow: Swift.UInt32 = 1
public let xwaylandProtocolTakeFocus: Swift.UInt32 = 2
public let xwaylandProtocolPing: Swift.UInt32 = 4
public let xwaylandProtocolSyncRequest: Swift.UInt32 = 8
public let xwaylandWindowTypeNormal: Swift.UInt64 = 1
public let xwaylandWindowTypeDialog: Swift.UInt64 = 2
public let xwaylandWindowTypeUtility: Swift.UInt64 = 4
public let xwaylandWindowTypeToolbar: Swift.UInt64 = 8
public let xwaylandWindowTypeSplash: Swift.UInt64 = 16
public let xwaylandWindowTypeMenu: Swift.UInt64 = 32
public let xwaylandWindowTypeDropdownMenu: Swift.UInt64 = 64
public let xwaylandWindowTypePopupMenu: Swift.UInt64 = 128
public let xwaylandWindowTypeTooltip: Swift.UInt64 = 256
public let xwaylandWindowTypeNotification: Swift.UInt64 = 512
public let xwaylandWindowTypeDock: Swift.UInt64 = 1024
public let xwaylandWindowTypeDesktop: Swift.UInt64 = 2048
public let xwaylandWindowTypeDnd: Swift.UInt64 = 4096
public let xwaylandWindowTypeCombo: Swift.UInt64 = 8192
public let xwaylandNetStateFullscreen: Swift.UInt64 = 1
public let xwaylandNetStateMaximizedVert: Swift.UInt64 = 2
public let xwaylandNetStateMaximizedHorz: Swift.UInt64 = 4
public let xwaylandNetStateHidden: Swift.UInt64 = 8
public let xwaylandNetStateAbove: Swift.UInt64 = 16
public let xwaylandNetStateBelow: Swift.UInt64 = 32
public let xwaylandNetStateDemandsAttention: Swift.UInt64 = 64
public let xwaylandNetStateModal: Swift.UInt64 = 128
public let xwaylandNetStateSkipTaskbar: Swift.UInt64 = 256
public let xwaylandNetStateSkipPager: Swift.UInt64 = 512
public let xwaylandNetStateSticky: Swift.UInt64 = 1024
public let xwaylandNetStateFocused: Swift.UInt64 = 2048
public let xwaylandFocusSetInput: Swift.UInt32 = 1
public let xwaylandFocusTakeFocus: Swift.UInt32 = 2
public let xwaylandFocusClear: Swift.UInt32 = 4
public let xwaylandFocusDenied: Swift.UInt32 = 8
public let xwaylandCloseNone: Swift.UInt32 = 0
public let xwaylandCloseDeleteWindow: Swift.UInt32 = 1
public let xwaylandCloseDestroy: Swift.UInt32 = 2

public struct WireLogicalRect: Swift.Equatable, Swift.Sendable {
  public var x: Swift.Double
  public var y: Swift.Double
  public var width: Swift.Double
  public var height: Swift.Double
  public init(x: Swift.Double = 0, y: Swift.Double = 0, width: Swift.Double = 0, height: Swift.Double = 0) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct WireRenderRect: Swift.Equatable, Swift.Sendable {
  public var x: Swift.Double
  public var y: Swift.Double
  public var w: Swift.Double
  public var h: Swift.Double
  public init(x: Swift.Double = 0, y: Swift.Double = 0, w: Swift.Double = 0, h: Swift.Double = 0) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }
}

public struct WirePixelSize: Swift.Equatable, Swift.Sendable {
  public var width: Swift.UInt32
  public var height: Swift.UInt32
  public init(width: Swift.UInt32 = Swift.UInt32(), height: Swift.UInt32 = Swift.UInt32()) {
    self.width = width
    self.height = height
  }
}

public struct WirePhysicalRect: Swift.Equatable, Swift.Sendable {
  public var x: Swift.Int32
  public var y: Swift.Int32
  public var width: Swift.UInt32
  public var height: Swift.UInt32
  public init(x: Swift.Int32 = Swift.Int32(), y: Swift.Int32 = Swift.Int32(), width: Swift.UInt32 = Swift.UInt32(), height: Swift.UInt32 = Swift.UInt32()) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct WireUsableArea: Swift.Equatable, Swift.Sendable {
  public var x: Swift.Int32
  public var y: Swift.Int32
  public var w: Swift.Int32
  public var h: Swift.Int32
  public init(x: Swift.Int32 = Swift.Int32(), y: Swift.Int32 = Swift.Int32(), w: Swift.Int32 = Swift.Int32(), h: Swift.Int32 = Swift.Int32()) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }
}

public struct WireDisplayMode: Swift.Equatable, Swift.Sendable {
  public var pixelWidth: Swift.UInt32
  public var pixelHeight: Swift.UInt32
  public var refreshMhz: Swift.Int32
  public init(pixelWidth: Swift.UInt32 = Swift.UInt32(), pixelHeight: Swift.UInt32 = Swift.UInt32(), refreshMhz: Swift.Int32 = Swift.Int32()) {
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.refreshMhz = refreshMhz
  }
}

public struct WireDisplayConfiguration: Swift.Equatable, Swift.Sendable {
  public var enabled: Swift.Bool
  public var primary: Swift.Bool
  public var reserved0: Swift.UInt16
  public var scale: Swift.UInt32
  public var logicalX: Swift.Double
  public var logicalY: Swift.Double
  public var logicalWidth: Swift.Double
  public var logicalHeight: Swift.Double
  public var fractionalScale: Swift.Double
  public var mode: NucleusCompositorServerTypes.WireDisplayMode
  public init(enabled: Swift.Bool = false, primary: Swift.Bool = false, reserved0: Swift.UInt16 = Swift.UInt16(), scale: Swift.UInt32 = Swift.UInt32(), logicalX: Swift.Double = 0, logicalY: Swift.Double = 0, logicalWidth: Swift.Double = 0, logicalHeight: Swift.Double = 0, fractionalScale: Swift.Double = 0, mode: NucleusCompositorServerTypes.WireDisplayMode = NucleusCompositorServerTypes.WireDisplayMode()) {
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

public struct WireDisplayConfigurationChanges: Swift.Equatable, Swift.Sendable {
  public var mask: Swift.UInt64
  public var enabled: Swift.Bool
  public var primary: Swift.Bool
  public var reserved0: Swift.UInt16
  public var scale: Swift.UInt32
  public var logicalX: Swift.Double
  public var logicalY: Swift.Double
  public var logicalWidth: Swift.Double
  public var logicalHeight: Swift.Double
  public var fractionalScale: Swift.Double
  public var mode: NucleusCompositorServerTypes.WireDisplayMode
  public init(mask: Swift.UInt64 = Swift.UInt64(), enabled: Swift.Bool = false, primary: Swift.Bool = false, reserved0: Swift.UInt16 = Swift.UInt16(), scale: Swift.UInt32 = Swift.UInt32(), logicalX: Swift.Double = 0, logicalY: Swift.Double = 0, logicalWidth: Swift.Double = 0, logicalHeight: Swift.Double = 0, fractionalScale: Swift.Double = 0, mode: NucleusCompositorServerTypes.WireDisplayMode = NucleusCompositorServerTypes.WireDisplayMode()) {
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

public struct WireWindowRect: Swift.Equatable, Swift.Sendable {
  public var x: Swift.Double
  public var y: Swift.Double
  public var width: Swift.UInt32
  public var height: Swift.UInt32
  public init(x: Swift.Double = 0, y: Swift.Double = 0, width: Swift.UInt32 = Swift.UInt32(), height: Swift.UInt32 = Swift.UInt32()) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct WireChromeInsets: Swift.Equatable, Swift.Sendable {
  public var top: Swift.Double
  public var left: Swift.Double
  public var bottom: Swift.Double
  public var right: Swift.Double
  public init(top: Swift.Double = 0, left: Swift.Double = 0, bottom: Swift.Double = 0, right: Swift.Double = 0) {
    self.top = top
    self.left = left
    self.bottom = bottom
    self.right = right
  }
}

public struct WireRequestedSpecialMode: Swift.Equatable, Swift.Sendable {
  public var activeMaximized: Swift.Bool
  public var activeFullscreen: Swift.Bool
  public var willSpecial: Swift.Bool
  public var reserved0: Swift.UInt8
  public init(activeMaximized: Swift.Bool = false, activeFullscreen: Swift.Bool = false, willSpecial: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8()) {
    self.activeMaximized = activeMaximized
    self.activeFullscreen = activeFullscreen
    self.willSpecial = willSpecial
    self.reserved0 = reserved0
  }
}

public struct WireLayoutRects: Swift.Equatable, Swift.Sendable {
  public var fullscreen: NucleusCompositorServerTypes.WireWindowRect
  public var maximized: NucleusCompositorServerTypes.WireWindowRect
  public var defaultRect: NucleusCompositorServerTypes.WireWindowRect
  public init(fullscreen: NucleusCompositorServerTypes.WireWindowRect = NucleusCompositorServerTypes.WireWindowRect(), maximized: NucleusCompositorServerTypes.WireWindowRect = NucleusCompositorServerTypes.WireWindowRect(), defaultRect: NucleusCompositorServerTypes.WireWindowRect = NucleusCompositorServerTypes.WireWindowRect()) {
    self.fullscreen = fullscreen
    self.maximized = maximized
    self.defaultRect = defaultRect
  }
}

public struct WireWindowPolicySnapshot: Swift.Equatable, Swift.Sendable {
  public var policyOutputId: Swift.UInt64
  public var requestedFullscreenOutputId: Swift.UInt64
  public var requestedMaximizedOutputId: Swift.UInt64
  public var requestedSpecial: NucleusCompositorServerTypes.WireRequestedSpecialMode
  public var activeMaximized: Swift.Bool
  public var activeFullscreen: Swift.Bool
  public var managedAppWindow: Swift.Bool
  public var wantsKeyboardFocus: Swift.Bool
  public var reserved0: Swift.UInt32
  public init(policyOutputId: Swift.UInt64 = Swift.UInt64(), requestedFullscreenOutputId: Swift.UInt64 = Swift.UInt64(), requestedMaximizedOutputId: Swift.UInt64 = Swift.UInt64(), requestedSpecial: NucleusCompositorServerTypes.WireRequestedSpecialMode = NucleusCompositorServerTypes.WireRequestedSpecialMode(), activeMaximized: Swift.Bool = false, activeFullscreen: Swift.Bool = false, managedAppWindow: Swift.Bool = false, wantsKeyboardFocus: Swift.Bool = false, reserved0: Swift.UInt32 = Swift.UInt32()) {
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

public struct WireWindowRenderOrderEntry: Swift.Equatable, Swift.Sendable {
  public var windowId: Swift.UInt64
  public var policy: NucleusCompositorServerTypes.WireWindowPolicySnapshot
  public init(windowId: Swift.UInt64 = Swift.UInt64(), policy: NucleusCompositorServerTypes.WireWindowPolicySnapshot = NucleusCompositorServerTypes.WireWindowPolicySnapshot()) {
    self.windowId = windowId
    self.policy = policy
  }
}

public struct WireOutputLayoutSnapshot: Swift.Equatable, Swift.Sendable {
  public var fullscreenRect: NucleusCompositorServerTypes.WireWindowRect
  public var maximizedRect: NucleusCompositorServerTypes.WireWindowRect
  public var defaultRect: NucleusCompositorServerTypes.WireWindowRect
  public init(fullscreenRect: NucleusCompositorServerTypes.WireWindowRect = NucleusCompositorServerTypes.WireWindowRect(), maximizedRect: NucleusCompositorServerTypes.WireWindowRect = NucleusCompositorServerTypes.WireWindowRect(), defaultRect: NucleusCompositorServerTypes.WireWindowRect = NucleusCompositorServerTypes.WireWindowRect()) {
    self.fullscreenRect = fullscreenRect
    self.maximizedRect = maximizedRect
    self.defaultRect = defaultRect
  }
}

public struct WireEventRecord: Swift.Equatable, Swift.Sendable {
  public var _kind: Swift.UInt32
  public var flags: Swift.UInt64
  public var timestampNs: Swift.UInt64
  public var x: Swift.Double
  public var y: Swift.Double
  public var data0: Swift.UInt64
  public var data1: Swift.UInt64
  public var data2: Swift.UInt64
  public var data3: Swift.UInt64
  public init(kind: WireEventKind = .nullEvent, flags: Swift.UInt64 = Swift.UInt64(), timestampNs: Swift.UInt64 = Swift.UInt64(), x: Swift.Double = 0, y: Swift.Double = 0, data0: Swift.UInt64 = Swift.UInt64(), data1: Swift.UInt64 = Swift.UInt64(), data2: Swift.UInt64 = Swift.UInt64(), data3: Swift.UInt64 = Swift.UInt64()) {
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
  public var kind: WireEventKind {
    get { WireEventKind(rawValue: _kind)! }
    set { _kind = newValue.rawValue }
  }
}

public struct WirePointerBounds: Swift.Equatable, Swift.Sendable {
  public var minX: Swift.Double
  public var minY: Swift.Double
  public var maxX: Swift.Double
  public var maxY: Swift.Double
  public init(minX: Swift.Double = 0, minY: Swift.Double = 0, maxX: Swift.Double = 0, maxY: Swift.Double = 0) {
    self.minX = minX
    self.minY = minY
    self.maxX = maxX
    self.maxY = maxY
  }
}

public struct WireEventStateSnapshot: Swift.Equatable, Swift.Sendable {
  public var cursorX: Swift.Double
  public var cursorY: Swift.Double
  public var flags: Swift.UInt64
  public var leftButtonDown: Swift.Bool
  public var rightButtonDown: Swift.Bool
  public var otherButtonCount: Swift.UInt8
  public var reserved0: Swift.UInt8
  public init(cursorX: Swift.Double = 0, cursorY: Swift.Double = 0, flags: Swift.UInt64 = Swift.UInt64(), leftButtonDown: Swift.Bool = false, rightButtonDown: Swift.Bool = false, otherButtonCount: Swift.UInt8 = Swift.UInt8(), reserved0: Swift.UInt8 = Swift.UInt8()) {
    self.cursorX = cursorX
    self.cursorY = cursorY
    self.flags = flags
    self.leftButtonDown = leftButtonDown
    self.rightButtonDown = rightButtonDown
    self.otherButtonCount = otherButtonCount
    self.reserved0 = reserved0
  }
}

public struct WireEventStateChange: Swift.Equatable, Swift.Sendable {
  public var cursorMoved: Swift.Bool
  public var buttonChanged: Swift.Bool
  public var flagsChanged: Swift.Bool
  public var reserved0: Swift.UInt8
  public init(cursorMoved: Swift.Bool = false, buttonChanged: Swift.Bool = false, flagsChanged: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8()) {
    self.cursorMoved = cursorMoved
    self.buttonChanged = buttonChanged
    self.flagsChanged = flagsChanged
    self.reserved0 = reserved0
  }
}

public struct WireEventDispatchDecision: Swift.Equatable, Swift.Sendable {
  public var _action: Swift.UInt32
  public var dispatchValue: Swift.Int32
  public var event: NucleusCompositorServerTypes.WireEventRecord
  public var state: NucleusCompositorServerTypes.WireEventStateSnapshot
  public var change: NucleusCompositorServerTypes.WireEventStateChange
  public init(action: WireEventDispatchAction = .route, dispatchValue: Swift.Int32 = Swift.Int32(), event: NucleusCompositorServerTypes.WireEventRecord = NucleusCompositorServerTypes.WireEventRecord(), state: NucleusCompositorServerTypes.WireEventStateSnapshot = NucleusCompositorServerTypes.WireEventStateSnapshot(), change: NucleusCompositorServerTypes.WireEventStateChange = NucleusCompositorServerTypes.WireEventStateChange()) {
    self._action = action.rawValue
    self.dispatchValue = dispatchValue
    self.event = event
    self.state = state
    self.change = change
  }
  public var action: WireEventDispatchAction {
    get { WireEventDispatchAction(rawValue: _action)! }
    set { _action = newValue.rawValue }
  }
}

public struct WireSeatFocusSnapshot: Swift.Equatable, Swift.Sendable {
  public var pointerSurfaceId: Swift.UInt64
  public var keyboardSurfaceId: Swift.UInt64
  public var buttonCount: Swift.UInt32
  public var lastPointerButtonSerial: Swift.UInt32
  public var lastPointerButtonSurfaceId: Swift.UInt64
  public init(pointerSurfaceId: Swift.UInt64 = Swift.UInt64(), keyboardSurfaceId: Swift.UInt64 = Swift.UInt64(), buttonCount: Swift.UInt32 = Swift.UInt32(), lastPointerButtonSerial: Swift.UInt32 = Swift.UInt32(), lastPointerButtonSurfaceId: Swift.UInt64 = Swift.UInt64()) {
    self.pointerSurfaceId = pointerSurfaceId
    self.keyboardSurfaceId = keyboardSurfaceId
    self.buttonCount = buttonCount
    self.lastPointerButtonSerial = lastPointerButtonSerial
    self.lastPointerButtonSurfaceId = lastPointerButtonSurfaceId
  }
}

public struct WireResizeEdges: Swift.Equatable, Swift.Sendable {
  public var top: Swift.Bool
  public var bottom: Swift.Bool
  public var left: Swift.Bool
  public var right: Swift.Bool
  public init(top: Swift.Bool = false, bottom: Swift.Bool = false, left: Swift.Bool = false, right: Swift.Bool = false) {
    self.top = top
    self.bottom = bottom
    self.left = left
    self.right = right
  }
}

public struct WireInteractionGrabUpdate: Swift.Equatable, Swift.Sendable {
  public var hasUpdate: Swift.Bool
  public var needsResizeConfigure: Swift.Bool
  public var reserved0: Swift.UInt16
  public var _mode: Swift.UInt32
  public var windowId: Swift.UInt64
  public var rect: NucleusCompositorServerTypes.WireWindowRect
  public init(hasUpdate: Swift.Bool = false, needsResizeConfigure: Swift.Bool = false, reserved0: Swift.UInt16 = Swift.UInt16(), mode: WireInteractionMode = .move, windowId: Swift.UInt64 = Swift.UInt64(), rect: NucleusCompositorServerTypes.WireWindowRect = NucleusCompositorServerTypes.WireWindowRect()) {
    self.hasUpdate = hasUpdate
    self.needsResizeConfigure = needsResizeConfigure
    self.reserved0 = reserved0
    self._mode = mode.rawValue
    self.windowId = windowId
    self.rect = rect
  }
  public var mode: WireInteractionMode {
    get { WireInteractionMode(rawValue: _mode)! }
    set { _mode = newValue.rawValue }
  }
}

public struct WireOutputMigrationResult: Swift.Equatable, Swift.Sendable {
  public var managed: Swift.Bool
  public var changed: Swift.Bool
  public var specialChanged: Swift.Bool
  public var reserved0: Swift.UInt8
  public init(managed: Swift.Bool = false, changed: Swift.Bool = false, specialChanged: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8()) {
    self.managed = managed
    self.changed = changed
    self.specialChanged = specialChanged
    self.reserved0 = reserved0
  }
}

public struct WirePopupPositioner: Swift.Equatable, Swift.Sendable {
  public var sizeW: Swift.Int32
  public var sizeH: Swift.Int32
  public var anchorRectX: Swift.Int32
  public var anchorRectY: Swift.Int32
  public var anchorRectW: Swift.Int32
  public var anchorRectH: Swift.Int32
  public var anchor: Swift.UInt32
  public var gravity: Swift.UInt32
  public var constraintAdjustment: Swift.UInt32
  public var reserved0: Swift.UInt32
  public var offsetX: Swift.Int32
  public var offsetY: Swift.Int32
  public init(sizeW: Swift.Int32 = Swift.Int32(), sizeH: Swift.Int32 = Swift.Int32(), anchorRectX: Swift.Int32 = Swift.Int32(), anchorRectY: Swift.Int32 = Swift.Int32(), anchorRectW: Swift.Int32 = Swift.Int32(), anchorRectH: Swift.Int32 = Swift.Int32(), anchor: Swift.UInt32 = Swift.UInt32(), gravity: Swift.UInt32 = Swift.UInt32(), constraintAdjustment: Swift.UInt32 = Swift.UInt32(), reserved0: Swift.UInt32 = Swift.UInt32(), offsetX: Swift.Int32 = Swift.Int32(), offsetY: Swift.Int32 = Swift.Int32()) {
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

public struct WirePopupResolvedRect: Swift.Equatable, Swift.Sendable {
  public var x: Swift.Int32
  public var y: Swift.Int32
  public var w: Swift.Int32
  public var h: Swift.Int32
  public init(x: Swift.Int32 = Swift.Int32(), y: Swift.Int32 = Swift.Int32(), w: Swift.Int32 = Swift.Int32(), h: Swift.Int32 = Swift.Int32()) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }
}

public struct WireBackdropLayerInput: Swift.Equatable, Swift.Sendable {
  public var layerId: Swift.UInt64
  public var frameX: Swift.Double
  public var frameY: Swift.Double
  public var frameWidth: Swift.Double
  public var frameHeight: Swift.Double
  public var isOpaqueOccluder: Swift.Bool
  public var reserved0: Swift.UInt8
  public var reserved1: Swift.UInt16
  public var reserved2: Swift.UInt32
  public var producerGroupId: Swift.UInt64
  public init(layerId: Swift.UInt64 = Swift.UInt64(), frameX: Swift.Double = 0, frameY: Swift.Double = 0, frameWidth: Swift.Double = 0, frameHeight: Swift.Double = 0, isOpaqueOccluder: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8(), reserved1: Swift.UInt16 = Swift.UInt16(), reserved2: Swift.UInt32 = Swift.UInt32(), producerGroupId: Swift.UInt64 = Swift.UInt64()) {
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

public struct WireBackdropAccessibility: Swift.Equatable, Swift.Sendable {
  public var reduceTransparency: Swift.Bool
  public var systemAppearance: Swift.UInt8
  public var increaseContrast: Swift.Bool
  public var reserved1: Swift.UInt8
  public init(reduceTransparency: Swift.Bool = false, systemAppearance: Swift.UInt8 = Swift.UInt8(), increaseContrast: Swift.Bool = false, reserved1: Swift.UInt8 = Swift.UInt8()) {
    self.reduceTransparency = reduceTransparency
    self.systemAppearance = systemAppearance
    self.increaseContrast = increaseContrast
    self.reserved1 = reserved1
  }
}

public struct WireBackdropMaterialInput: Swift.Equatable, Swift.Sendable {
  public var layerId: Swift.UInt64
  public var material: Swift.UInt32
  public var requestedState: Swift.UInt32
  public var appearance: Swift.UInt8
  public var isEmphasized: Swift.Bool
  public var hasOwningWindow: Swift.Bool
  public var reserved0: Swift.UInt8
  public var owningWindowId: Swift.UInt64
  public var tintR: Swift.Float
  public var tintG: Swift.Float
  public var tintB: Swift.Float
  public var tintA: Swift.Float
  public var opacity: Swift.Float
  public init(layerId: Swift.UInt64 = Swift.UInt64(), material: Swift.UInt32 = Swift.UInt32(), requestedState: Swift.UInt32 = Swift.UInt32(), appearance: Swift.UInt8 = Swift.UInt8(), isEmphasized: Swift.Bool = false, hasOwningWindow: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8(), owningWindowId: Swift.UInt64 = Swift.UInt64(), tintR: Swift.Float = 0, tintG: Swift.Float = 0, tintB: Swift.Float = 0, tintA: Swift.Float = 0, opacity: Swift.Float = 0) {
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

public struct WireBackdropMaterialSpec: Swift.Equatable, Swift.Sendable {
  public var layerId: Swift.UInt64
  public var enabled: Swift.Bool
  public var passes: Swift.UInt8
  public var foregroundVariant: Swift.UInt8
  public var resolvedAppearance: Swift.UInt8
  public var resolvedState: Swift.UInt32
  public var needsFrame: Swift.Bool
  public var reserved0: Swift.UInt8
  public var reserved1: Swift.UInt16
  public var offset: Swift.Float
  public var saturation: Swift.Float
  public var tintR: Swift.Float
  public var tintG: Swift.Float
  public var tintB: Swift.Float
  public var tintA: Swift.Float
  public var tintBlend: Swift.Float
  public var noise: Swift.Float
  public var alpha: Swift.Float
  public var solidFallbackR: Swift.Float
  public var solidFallbackG: Swift.Float
  public var solidFallbackB: Swift.Float
  public var solidFallbackA: Swift.Float
  public init(layerId: Swift.UInt64 = Swift.UInt64(), enabled: Swift.Bool = false, passes: Swift.UInt8 = Swift.UInt8(), foregroundVariant: Swift.UInt8 = Swift.UInt8(), resolvedAppearance: Swift.UInt8 = Swift.UInt8(), resolvedState: Swift.UInt32 = Swift.UInt32(), needsFrame: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8(), reserved1: Swift.UInt16 = Swift.UInt16(), offset: Swift.Float = 0, saturation: Swift.Float = 0, tintR: Swift.Float = 0, tintG: Swift.Float = 0, tintB: Swift.Float = 0, tintA: Swift.Float = 0, tintBlend: Swift.Float = 0, noise: Swift.Float = 0, alpha: Swift.Float = 0, solidFallbackR: Swift.Float = 0, solidFallbackG: Swift.Float = 0, solidFallbackB: Swift.Float = 0, solidFallbackA: Swift.Float = 0) {
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

public struct WireBackdropDraw: Swift.Equatable, Swift.Sendable {
  public var layerId: Swift.UInt64
  public var regionX: Swift.Double
  public var regionY: Swift.Double
  public var regionWidth: Swift.Double
  public var regionHeight: Swift.Double
  public var groupId: Swift.UInt64
  public var resolvedState: Swift.UInt32
  public var resolvedAppearance: Swift.UInt8
  public var reserved0: Swift.UInt8
  public var reserved1: Swift.UInt8
  public var reserved2: Swift.UInt8
  public init(layerId: Swift.UInt64 = Swift.UInt64(), regionX: Swift.Double = 0, regionY: Swift.Double = 0, regionWidth: Swift.Double = 0, regionHeight: Swift.Double = 0, groupId: Swift.UInt64 = Swift.UInt64(), resolvedState: Swift.UInt32 = Swift.UInt32(), resolvedAppearance: Swift.UInt8 = Swift.UInt8(), reserved0: Swift.UInt8 = Swift.UInt8(), reserved1: Swift.UInt8 = Swift.UInt8(), reserved2: Swift.UInt8 = Swift.UInt8()) {
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
