import Swift

public enum InputKind: Swift.UInt32, Swift.Sendable {
  case pointerMove = 1
  case pointerDown = 2
  case pointerUp = 3
  case scroll = 4
  case keyDown = 5
  case keyUp = 6
}

public enum CursorKind: Swift.UInt32, Swift.Sendable {
  case `default` = 0
  case pointer = 1
}

public enum VisualContentKind: Swift.Sendable, Swift.Equatable {
  case nativeLayer
  case hostedSurface
  case unknown(Swift.UInt8)
  public init(rawValue: Swift.UInt8) {
    switch rawValue {
    case 1: self = .nativeLayer
    case 2: self = .hostedSurface
    default: self = .unknown(rawValue)
    }
  }
  public var rawValue: Swift.UInt8 {
    switch self {
    case .nativeLayer: 1
    case .hostedSurface: 2
    case .unknown(let rawValue): rawValue
    }
  }
}

public enum KeybindKind: Swift.UInt8, Swift.Sendable {
  case pass = 0
  case consume = 1
  case deferred = 2
}

public enum KeybindAction: Swift.UInt8, Swift.Sendable {
  case none = 0
  case closeFocused = 1
  case toggleHotkey = 3
  case dismissHotkey = 4
  case wallpaper = 5
  case windowMenu = 6
  case tile = 7
  case backdropChanged = 8
  case activateWorkspace = 9
  case moveWindowToWorkspace = 10
}

public struct FrameInfo: Swift.Equatable, Swift.Sendable {
  public var outputWidth: Swift.UInt32
  public var outputHeight: Swift.UInt32
  public var devicePixelRatio: Swift.Float
  public var overlayRegionX: Swift.Float
  public var overlayRegionY: Swift.Float
  public var overlayRegionW: Swift.Float
  public var overlayRegionH: Swift.Float
  public init(outputWidth: Swift.UInt32 = Swift.UInt32(), outputHeight: Swift.UInt32 = Swift.UInt32(), devicePixelRatio: Swift.Float = 0, overlayRegionX: Swift.Float = 0, overlayRegionY: Swift.Float = 0, overlayRegionW: Swift.Float = 0, overlayRegionH: Swift.Float = 0) {
    self.outputWidth = outputWidth
    self.outputHeight = outputHeight
    self.devicePixelRatio = devicePixelRatio
    self.overlayRegionX = overlayRegionX
    self.overlayRegionY = overlayRegionY
    self.overlayRegionW = overlayRegionW
    self.overlayRegionH = overlayRegionH
  }
}

public struct OutputSize: Swift.Equatable, Swift.Sendable {
  public var width: Swift.UInt32
  public var height: Swift.UInt32
  public var scale: Swift.Float
  public init(width: Swift.UInt32 = Swift.UInt32(), height: Swift.UInt32 = Swift.UInt32(), scale: Swift.Float = 0) {
    self.width = width
    self.height = height
    self.scale = scale
  }
}

public struct InputEvent: Swift.Equatable, Swift.Sendable {
  public var _kind: Swift.UInt32
  public var button: Swift.UInt32
  public var x: Swift.Float
  public var y: Swift.Float
  public var scrollX: Swift.Float
  public var scrollY: Swift.Float
  public var keycode: Swift.UInt32
  public var modifiers: Swift.UInt32
  /// Composed text for a key event, as produced by the compositor's XKB state.
  /// Carried alongside `keycode` rather than derived from it: a keycode cannot
  /// account for layout, dead keys, or compose sequences.
  public var text: Swift.String?
  public var timestampNs: Swift.UInt64
  public init(kind: InputKind = .pointerMove, button: Swift.UInt32 = Swift.UInt32(), x: Swift.Float = 0, y: Swift.Float = 0, scrollX: Swift.Float = 0, scrollY: Swift.Float = 0, keycode: Swift.UInt32 = Swift.UInt32(), modifiers: Swift.UInt32 = Swift.UInt32(), text: Swift.String? = nil, timestampNs: Swift.UInt64 = Swift.UInt64()) {
    self._kind = kind.rawValue
    self.button = button
    self.x = x
    self.y = y
    self.scrollX = scrollX
    self.scrollY = scrollY
    self.keycode = keycode
    self.modifiers = modifiers
    self.text = text
    self.timestampNs = timestampNs
  }
  public var kind: InputKind {
    get { InputKind(rawValue: _kind)! }
    set { _kind = newValue.rawValue }
  }
}

public struct InputResult: Swift.Equatable, Swift.Sendable {
  public var consumed: Swift.Bool
  public var wantsFrame: Swift.Bool
  public var reserved: Swift.UInt16
  public var _cursor: Swift.UInt32
  public init(consumed: Swift.Bool = false, wantsFrame: Swift.Bool = false, reserved: Swift.UInt16 = Swift.UInt16(), cursor: CursorKind = .`default`) {
    self.consumed = consumed
    self.wantsFrame = wantsFrame
    self.reserved = reserved
    self._cursor = cursor.rawValue
  }
  public var cursor: CursorKind {
    get { CursorKind(rawValue: _cursor)! }
    set { _cursor = newValue.rawValue }
  }
}

public struct SceneInfo: Swift.Equatable, Swift.Sendable {
  public var frame: NucleusCompositorOverlayTypes.FrameInfo
  public init(frame: NucleusCompositorOverlayTypes.FrameInfo = NucleusCompositorOverlayTypes.FrameInfo()) {
    self.frame = frame
  }
}

public struct VisualContentItem: Swift.Equatable, Swift.Sendable {
  public var _kind: Swift.UInt8
  public var visible: Swift.Bool
  public var reserved0: Swift.UInt16
  public var orderIndex: Swift.UInt32
  public var id: Swift.UInt64
  public var rootLayerId: Swift.UInt64
  public init(kind: VisualContentKind = .nativeLayer, visible: Swift.Bool = false, reserved0: Swift.UInt16 = Swift.UInt16(), orderIndex: Swift.UInt32 = Swift.UInt32(), id: Swift.UInt64 = Swift.UInt64(), rootLayerId: Swift.UInt64 = Swift.UInt64()) {
    self._kind = kind.rawValue
    self.visible = visible
    self.reserved0 = reserved0
    self.orderIndex = orderIndex
    self.id = id
    self.rootLayerId = rootLayerId
  }
  public var kind: VisualContentKind {
    get { VisualContentKind(rawValue: _kind) }
    set { _kind = newValue.rawValue }
  }
}

public struct KeybindDecision: Swift.Equatable, Swift.Sendable {
  public var _kind: Swift.UInt8
  public var _action: Swift.UInt8
  public var reserved: Swift.UInt16
  public var value: Swift.UInt32
  public init(kind: KeybindKind = .pass, action: KeybindAction = .none, reserved: Swift.UInt16 = Swift.UInt16(), value: Swift.UInt32 = Swift.UInt32()) {
    self._kind = kind.rawValue
    self._action = action.rawValue
    self.reserved = reserved
    self.value = value
  }
  public var kind: KeybindKind {
    get { KeybindKind(rawValue: _kind)! }
    set { _kind = newValue.rawValue }
  }
  public var action: KeybindAction {
    get { KeybindAction(rawValue: _action)! }
    set { _action = newValue.rawValue }
  }
}
