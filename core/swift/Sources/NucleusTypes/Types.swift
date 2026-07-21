import Swift

public enum ActionPolicy: Swift.UInt8, Swift.Sendable {
  case none = 0
  case `default` = 1
  case explicit = 2
}

public enum AnimationCurveKind: Swift.UInt32, Swift.Sendable {
  case linear = 0
  case bezier = 1
  case spring = 2
}

public enum AnimationKeyPath: Swift.UInt32, Swift.Sendable {
  case none = 0
  case opacity = 1
  case cornerRadius = 2
  case positionX = 3
  case positionY = 4
  case boundsW = 5
  case boundsH = 6
  case anchorPointX = 7
  case anchorPointY = 8
  case transform = 9
  case scrollOffsetX = 10
  case scrollOffsetY = 11
  case borderTopWidth = 12
  case borderRightWidth = 13
  case borderBottomWidth = 14
  case borderLeftWidth = 15
}

public enum BackdropAppearance: Swift.UInt8, Swift.Sendable {
  case auto = 0
  case light = 1
  case dark = 2
}

public enum BackdropBlendingMode: Swift.UInt32, Swift.Sendable {
  case none = 0
  case behindWindow = 1
  case withinWindow = 2
}

public enum BackdropMask: Swift.UInt8, Swift.Sendable {
  case none = 0
  case roundedRect = 1
  case image = 2
}

public enum BackdropMaterialKind: Swift.UInt32, Swift.Sendable {
  case none = 0
  case `default` = 1
  case sidebar = 2
  case hudWindow = 3
  case menu = 4
  case popover = 5
  case titlebar = 6
  case sheet = 7
  case headerView = 8
  case selection = 9
  case underWindowBackground = 10
  case underPageBackground = 11
  case fullScreenUi = 12
  case toolTip = 13
  case windowBackground = 14
  case contentBackground = 15
  case shellOverlay = 16
}

public enum BackdropState: Swift.UInt32, Swift.Sendable {
  case active = 0
  case inactive = 1
  case followsWindowActiveState = 2
}

public enum ContentKind: Swift.UInt32, Swift.Sendable {
  case none = 0
  case paint = 1
  case external = 2
  case snapshot = 3
}

public enum EffectShape: Swift.UInt8, Swift.Sendable {
  case none = 0
  case rect = 1
  case rrect = 2
}

public enum ForegroundVibrancyMode: Swift.UInt8, Swift.Sendable {
  case inherit = 0
  case none = 1
  case light = 2
  case dark = 3
}

public enum LayerKind: Swift.UInt32, Swift.Sendable {
  case none = 0
  case container = 1
  case backdrop = 2
  case host = 3
}

public enum LayerRole: Swift.UInt8, Swift.Sendable {
  case generic = 0
  case windowRoot = 1
  case windowContentViewport = 2
  case notification = 3
  case hotkeyOverlay = 4
  case wallpaper = 5
  case dock = 6
}

public enum PaintCommandKind: Swift.UInt32, Swift.Sendable {
  case rect = 0
  case roundedRect = 1
  case image = 2
  /// Arbitrary geometry, with verbs and points in the payload. Subsumes the
  /// former `.line`, which was a second way to say the same thing.
  case path = 3
  case textLayout = 4
  /// Intersect the clip with the payload's path. Scoped by `save`/`restore`;
  /// the canvas is a state machine, so clipping cannot be baked into geometry
  /// the way a transform can.
  case clipPath = 5
  case save = 6
  case restore = 7
}

/// Source-over and the compositing modes the rasterizer's `Paint` already
/// carries. Mirrors `nucleus::skia::BlendMode` one-for-one.
public enum PaintBlendMode: Swift.UInt32, Swift.Sendable {
  case srcOver = 0
  case src = 1
  case multiply = 2
  case screen = 3
  case plus = 4
  case overlay = 5
  case dstIn = 6
  case dstOut = 7
}

/// Style/behavior bits on a paint command. `stroke` selects
/// `SkPaint::kStroke_Style` — without it a `strokeWidth` renders as a fill,
/// which is why borders paint solid today.
public struct PaintCommandFlags: Swift.OptionSet, Swift.Sendable {
  public var rawValue: Swift.UInt32
  public init(rawValue: Swift.UInt32) { self.rawValue = rawValue }

  public static let stroke = PaintCommandFlags(rawValue: 1 << 0)
  public static let antialias = PaintCommandFlags(rawValue: 1 << 1)
  public static let evenOddFill = PaintCommandFlags(rawValue: 1 << 2)
  /// Recolour an image draw by its alpha, keeping shape and dropping colour.
  public static let tintImage = PaintCommandFlags(rawValue: 1 << 3)

  /// Stroke cap and join. Absent bits mean the defaults — butt and miter —
  /// which is why neither needs a bit of its own.
  public static let capRound = PaintCommandFlags(rawValue: 1 << 4)
  public static let capSquare = PaintCommandFlags(rawValue: 1 << 5)
  public static let joinRound = PaintCommandFlags(rawValue: 1 << 6)
  public static let joinBevel = PaintCommandFlags(rawValue: 1 << 7)

  /// The command carries its own transform, and its geometry is stated in the
  /// space that transform maps from. Every paint and clip operation authored by
  /// `GraphicsContext` sets this bit, including for the identity matrix, so
  /// geometry and scalar style never take a separate pre-transformed path.
  public static let hasTransform = PaintCommandFlags(rawValue: 1 << 8)

  public static let `default`: PaintCommandFlags = [.antialias]
}

public enum ImplicitActionKeyPath: Swift.UInt8, Swift.Sendable {
  case frame = 1
  case opacity = 2
}

public enum ImplicitActionKind: Swift.UInt8, Swift.Sendable {
  case spring = 1
  case scalar = 2
}

public enum ScreenshotMode: Swift.UInt32, Swift.Sendable {
  case fullDisplay = 1
  case output = 2
  case region = 3
  case window = 4
}

public enum ScreenshotDestination: Swift.UInt32, Swift.Sendable {
  case file = 1
  case previewOnly = 2
  case clipboard = 3
}

public enum ScreenshotOrigin: Swift.UInt32, Swift.Sendable {
  case hotkey = 1
  case shellUi = 2
  case portal = 3
  case internalTest = 4
}

public enum ScreenshotEventKind: Swift.UInt32, Swift.Sendable {
  case previewReady = 1
  case saveComplete = 2
  case saveFailed = 3
}

public enum ScreenshotThumbnailUpdate: Swift.UInt8, Swift.Sendable {
  case none = 0
  case set = 1
  case clear = 2
}

public let rootContextId: Swift.UInt32 = 1
public let shellOverlayContextId: Swift.UInt32 = 62
public let ok: Swift.Int32 = 0
public let errorInvalidHandle: Swift.Int32 = 1
public let errorOutOfMemory: Swift.Int32 = 2
public let errorInvalidArgument: Swift.Int32 = 3
public let errorBackendFailure: Swift.Int32 = 4
public let errorNotImplemented: Swift.Int32 = 5
public let layerPropertyHidden: Swift.UInt64 = 2
public let layerPropertyOpacity: Swift.UInt64 = 4
public let layerPropertyVisualEffect: Swift.UInt64 = 8
public let layerPropertyShadow: Swift.UInt64 = 16
public let layerPropertyPosition: Swift.UInt64 = 32
public let layerPropertyBounds: Swift.UInt64 = 64
public let layerPropertyAnchorPoint: Swift.UInt64 = 128
public let layerPropertyTransform: Swift.UInt64 = 256
public let layerPropertyScrollOffset: Swift.UInt64 = 512
public let layerPropertyClip: Swift.UInt64 = 1024
public let layerPropertyCornerRadii: Swift.UInt64 = 2048
public let layerPropertyBorderTop: Swift.UInt64 = 4096
public let layerPropertyBorderRight: Swift.UInt64 = 8192
public let layerPropertyBorderBottom: Swift.UInt64 = 16384
public let layerPropertyBorderLeft: Swift.UInt64 = 32768
public let layerPropertyForegroundVibrancy: Swift.UInt64 = 65536
public let layerPropertyContent: Swift.UInt64 = 131072
public let layerPropertyBackdropGroup: Swift.UInt64 = 262144
public let layerPropertyContentSample: Swift.UInt64 = 524288
public let layerPropertyBackgroundEffect: Swift.UInt64 = 1048576
public let layerPropertyContentDamage: Swift.UInt64 = 2097152

public struct ImageHandle: Swift.Equatable, Swift.Sendable {
  public var id: Swift.UInt64
  public init(id: Swift.UInt64 = Swift.UInt64()) {
    self.id = id
  }
}

public struct Point: Swift.Equatable, Swift.Sendable {
  public var x: Swift.Double
  public var y: Swift.Double
  public init(x: Swift.Double = 0, y: Swift.Double = 0) {
    self.x = x
    self.y = y
  }
}

public struct Size: Swift.Equatable, Swift.Sendable {
  public var width: Swift.Double
  public var height: Swift.Double
  public init(width: Swift.Double = 0, height: Swift.Double = 0) {
    self.width = width
    self.height = height
  }
}

public struct Rect: Swift.Equatable, Swift.Sendable {
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

public struct PresentReport: Swift.Equatable, Swift.Sendable {
  public var predictedPresentationNs: Swift.UInt64
  public var targetPresentationNs: Swift.UInt64
  public var nextPresentId: Swift.UInt64
  public init(predictedPresentationNs: Swift.UInt64 = Swift.UInt64(), targetPresentationNs: Swift.UInt64 = Swift.UInt64(), nextPresentId: Swift.UInt64 = Swift.UInt64()) {
    self.predictedPresentationNs = predictedPresentationNs
    self.targetPresentationNs = targetPresentationNs
    self.nextPresentId = nextPresentId
  }
}

public struct ImplicitActionRow: Swift.Equatable, Swift.Sendable {
  public var _role: Swift.UInt8
  public var _keyPath: Swift.UInt8
  public var _kind: Swift.UInt8
  public var reserved: Swift.UInt8
  public var mass: Swift.Float
  public var stiffness: Swift.Float
  public var damping: Swift.Float
  public var reserved2: Swift.Float
  public var duration: Swift.Double
  public var c1x: Swift.Float
  public var c1y: Swift.Float
  public var c2x: Swift.Float
  public var c2y: Swift.Float
  public init(role: LayerRole = .generic, keyPath: ImplicitActionKeyPath = .frame, kind: ImplicitActionKind = .spring, reserved: Swift.UInt8 = Swift.UInt8(), mass: Swift.Float = 0, stiffness: Swift.Float = 0, damping: Swift.Float = 0, reserved2: Swift.Float = 0, duration: Swift.Double = 0, c1x: Swift.Float = 0, c1y: Swift.Float = 0, c2x: Swift.Float = 0, c2y: Swift.Float = 0) {
    self._role = role.rawValue
    self._keyPath = keyPath.rawValue
    self._kind = kind.rawValue
    self.reserved = reserved
    self.mass = mass
    self.stiffness = stiffness
    self.damping = damping
    self.reserved2 = reserved2
    self.duration = duration
    self.c1x = c1x
    self.c1y = c1y
    self.c2x = c2x
    self.c2y = c2y
  }
  public var role: LayerRole {
    get { LayerRole(rawValue: _role) ?? .generic }
    set { _role = newValue.rawValue }
  }
  public var keyPath: ImplicitActionKeyPath {
    get { ImplicitActionKeyPath(rawValue: _keyPath) ?? .frame }
    set { _keyPath = newValue.rawValue }
  }
  public var kind: ImplicitActionKind {
    get { ImplicitActionKind(rawValue: _kind) ?? .spring }
    set { _kind = newValue.rawValue }
  }
}

public struct ScreenshotRequest: Swift.Equatable, Swift.Sendable {
  public var requestId: Swift.UInt32
  public var _mode: Swift.UInt32
  public var targetOutput: Swift.UInt32
  public var _destinationKind: Swift.UInt32
  public var _origin: Swift.UInt32
  public var previewWidth: Swift.UInt32
  public var previewHeight: Swift.UInt32
  public var preview: Swift.Bool
  public var reserved0: Swift.UInt8
  public var reserved1: Swift.UInt16
  public var savePathLen: Swift.UInt
  public init(requestId: Swift.UInt32 = Swift.UInt32(), mode: ScreenshotMode = .fullDisplay, targetOutput: Swift.UInt32 = Swift.UInt32(), destinationKind: ScreenshotDestination = .file, origin: ScreenshotOrigin = .hotkey, previewWidth: Swift.UInt32 = Swift.UInt32(), previewHeight: Swift.UInt32 = Swift.UInt32(), preview: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8(), reserved1: Swift.UInt16 = Swift.UInt16(), savePathLen: Swift.UInt = 0) {
    self.requestId = requestId
    self._mode = mode.rawValue
    self.targetOutput = targetOutput
    self._destinationKind = destinationKind.rawValue
    self._origin = origin.rawValue
    self.previewWidth = previewWidth
    self.previewHeight = previewHeight
    self.preview = preview
    self.reserved0 = reserved0
    self.reserved1 = reserved1
    self.savePathLen = savePathLen
  }
  public var mode: ScreenshotMode {
    get { ScreenshotMode(rawValue: _mode) ?? .fullDisplay }
    set { _mode = newValue.rawValue }
  }
  public var destinationKind: ScreenshotDestination {
    get { ScreenshotDestination(rawValue: _destinationKind) ?? .file }
    set { _destinationKind = newValue.rawValue }
  }
  public var origin: ScreenshotOrigin {
    get { ScreenshotOrigin(rawValue: _origin) ?? .hotkey }
    set { _origin = newValue.rawValue }
  }
}

public struct ScreenshotEvent {
  public var requestId: Swift.UInt32
  public var _kind: Swift.UInt32
  public var statusCode: Swift.Int32
  public var reserved: Swift.UInt32
  public var thumbnailHandle: Swift.UInt64
  public var savedPathPtr: Swift.UnsafePointer<Swift.UInt8>?
  public var savedPathLen: Swift.UInt
  public init(requestId: Swift.UInt32 = Swift.UInt32(), kind: ScreenshotEventKind = .previewReady, statusCode: Swift.Int32 = Swift.Int32(), reserved: Swift.UInt32 = Swift.UInt32(), thumbnailHandle: Swift.UInt64 = Swift.UInt64(), savedPathPtr: Swift.UnsafePointer<Swift.UInt8>? = nil, savedPathLen: Swift.UInt = 0) {
    self.requestId = requestId
    self._kind = kind.rawValue
    self.statusCode = statusCode
    self.reserved = reserved
    self.thumbnailHandle = thumbnailHandle
    self.savedPathPtr = savedPathPtr
    self.savedPathLen = savedPathLen
  }
  public var kind: ScreenshotEventKind {
    get { ScreenshotEventKind(rawValue: _kind) ?? .previewReady }
    set { _kind = newValue.rawValue }
  }
}

public struct ScreenshotEventResult: Swift.Equatable, Swift.Sendable {
  public var overlayDirty: Swift.Bool
  public var _thumbnailUpdate: Swift.UInt8
  public var reserved0: Swift.UInt16
  public var reserved1: Swift.UInt32
  public var thumbnailHandle: Swift.UInt64
  public init(overlayDirty: Swift.Bool = false, thumbnailUpdate: ScreenshotThumbnailUpdate = .none, reserved0: Swift.UInt16 = Swift.UInt16(), reserved1: Swift.UInt32 = Swift.UInt32(), thumbnailHandle: Swift.UInt64 = Swift.UInt64()) {
    self.overlayDirty = overlayDirty
    self._thumbnailUpdate = thumbnailUpdate.rawValue
    self.reserved0 = reserved0
    self.reserved1 = reserved1
    self.thumbnailHandle = thumbnailHandle
  }
  public var thumbnailUpdate: ScreenshotThumbnailUpdate {
    get { ScreenshotThumbnailUpdate(rawValue: _thumbnailUpdate) ?? .none }
    set { _thumbnailUpdate = newValue.rawValue }
  }
}

public struct Color: Swift.Equatable, Swift.Sendable {
  public var r: Swift.Float
  public var g: Swift.Float
  public var b: Swift.Float
  public var a: Swift.Float
  public init(r: Swift.Float = 0, g: Swift.Float = 0, b: Swift.Float = 0, a: Swift.Float = 0) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }
}

public struct BorderEdge: Swift.Equatable, Swift.Sendable {
  public var width: Swift.Float
  public var color: NucleusTypes.Color
  public init(width: Swift.Float = 0, color: NucleusTypes.Color = NucleusTypes.Color()) {
    self.width = width
    self.color = color
  }
}

public struct Transform: Swift.Equatable, Swift.Sendable {
  public var m00: Swift.Double
  public var m01: Swift.Double
  public var m02: Swift.Double
  public var m03: Swift.Double
  public var m10: Swift.Double
  public var m11: Swift.Double
  public var m12: Swift.Double
  public var m13: Swift.Double
  public var m20: Swift.Double
  public var m21: Swift.Double
  public var m22: Swift.Double
  public var m23: Swift.Double
  public var m30: Swift.Double
  public var m31: Swift.Double
  public var m32: Swift.Double
  public var m33: Swift.Double
  public init(m00: Swift.Double = 0, m01: Swift.Double = 0, m02: Swift.Double = 0, m03: Swift.Double = 0, m10: Swift.Double = 0, m11: Swift.Double = 0, m12: Swift.Double = 0, m13: Swift.Double = 0, m20: Swift.Double = 0, m21: Swift.Double = 0, m22: Swift.Double = 0, m23: Swift.Double = 0, m30: Swift.Double = 0, m31: Swift.Double = 0, m32: Swift.Double = 0, m33: Swift.Double = 0) {
    self.m00 = m00
    self.m01 = m01
    self.m02 = m02
    self.m03 = m03
    self.m10 = m10
    self.m11 = m11
    self.m12 = m12
    self.m13 = m13
    self.m20 = m20
    self.m21 = m21
    self.m22 = m22
    self.m23 = m23
    self.m30 = m30
    self.m31 = m31
    self.m32 = m32
    self.m33 = m33
  }
}

public struct ClipOp: Swift.Equatable, Swift.Sendable {
  public var _rectX: Swift.Float
  public var _rectY: Swift.Float
  public var _rectW: Swift.Float
  public var _rectH: Swift.Float
  public var _radiusTl: Swift.Float
  public var _radiusTr: Swift.Float
  public var _radiusBr: Swift.Float
  public var _radiusBl: Swift.Float
  public var antiAlias: Swift.Bool
  public var reserved0: Swift.UInt8
  public var reserved1: Swift.UInt8
  public var reserved2: Swift.UInt8
  public var xform00: Swift.Float
  public var xform01: Swift.Float
  public var xform02: Swift.Float
  public var xform10: Swift.Float
  public var xform11: Swift.Float
  public var xform12: Swift.Float
  public var xform20: Swift.Float
  public var xform21: Swift.Float
  public var xform22: Swift.Float
  public init(rect: SIMD4<Float> = SIMD4<Float>(repeating: 0), radii: SIMD4<Float> = SIMD4<Float>(repeating: 0), antiAlias: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8(), reserved1: Swift.UInt8 = Swift.UInt8(), reserved2: Swift.UInt8 = Swift.UInt8(), xform00: Swift.Float = 0, xform01: Swift.Float = 0, xform02: Swift.Float = 0, xform10: Swift.Float = 0, xform11: Swift.Float = 0, xform12: Swift.Float = 0, xform20: Swift.Float = 0, xform21: Swift.Float = 0, xform22: Swift.Float = 0) {
    self._rectX = rect[0]
    self._rectY = rect[1]
    self._rectW = rect[2]
    self._rectH = rect[3]
    self._radiusTl = radii[0]
    self._radiusTr = radii[1]
    self._radiusBr = radii[2]
    self._radiusBl = radii[3]
    self.antiAlias = antiAlias
    self.reserved0 = reserved0
    self.reserved1 = reserved1
    self.reserved2 = reserved2
    self.xform00 = xform00
    self.xform01 = xform01
    self.xform02 = xform02
    self.xform10 = xform10
    self.xform11 = xform11
    self.xform12 = xform12
    self.xform20 = xform20
    self.xform21 = xform21
    self.xform22 = xform22
  }
  public var rect: SIMD4<Float> {
    get { SIMD4<Float>(_rectX, _rectY, _rectW, _rectH) }
    set {
      _rectX = newValue[0]
      _rectY = newValue[1]
      _rectW = newValue[2]
      _rectH = newValue[3]
    }
  }
  public var radii: SIMD4<Float> {
    get { SIMD4<Float>(_radiusTl, _radiusTr, _radiusBr, _radiusBl) }
    set {
      _radiusTl = newValue[0]
      _radiusTr = newValue[1]
      _radiusBr = newValue[2]
      _radiusBl = newValue[3]
    }
  }
}

public struct VisualEffect: Swift.Equatable, Swift.Sendable {
  public var _material: Swift.UInt32
  public var _blendingMode: Swift.UInt32
  public var _state: Swift.UInt32
  public var _appearance: Swift.UInt8
  public var emphasized: Swift.Bool
  public var _maskKind: Swift.UInt8
  public var _shapeKind: Swift.UInt8
  public var cornerRadius: Swift.Double
  public var opacity: Swift.Double
  public var tint: NucleusTypes.Color
  public var maskImageHandle: Swift.UInt64
  public var _shapeRectX: Swift.Float
  public var _shapeRectY: Swift.Float
  public var _shapeRectW: Swift.Float
  public var _shapeRectH: Swift.Float
  public var _shapeRadiusTl: Swift.Float
  public var _shapeRadiusTr: Swift.Float
  public var _shapeRadiusBr: Swift.Float
  public var _shapeRadiusBl: Swift.Float
  public init(material: BackdropMaterialKind = .none, blendingMode: BackdropBlendingMode = .none, state: BackdropState = .active, appearance: BackdropAppearance = .auto, emphasized: Swift.Bool = false, maskKind: BackdropMask = .none, shapeKind: EffectShape = .none, cornerRadius: Swift.Double = 0, opacity: Swift.Double = 0, tint: NucleusTypes.Color = NucleusTypes.Color(), maskImageHandle: Swift.UInt64 = Swift.UInt64(), shapeRect: SIMD4<Float> = SIMD4<Float>(repeating: 0), shapeRadius: SIMD4<Float> = SIMD4<Float>(repeating: 0)) {
    self._material = material.rawValue
    self._blendingMode = blendingMode.rawValue
    self._state = state.rawValue
    self._appearance = appearance.rawValue
    self.emphasized = emphasized
    self._maskKind = maskKind.rawValue
    self._shapeKind = shapeKind.rawValue
    self.cornerRadius = cornerRadius
    self.opacity = opacity
    self.tint = tint
    self.maskImageHandle = maskImageHandle
    self._shapeRectX = shapeRect[0]
    self._shapeRectY = shapeRect[1]
    self._shapeRectW = shapeRect[2]
    self._shapeRectH = shapeRect[3]
    self._shapeRadiusTl = shapeRadius[0]
    self._shapeRadiusTr = shapeRadius[1]
    self._shapeRadiusBr = shapeRadius[2]
    self._shapeRadiusBl = shapeRadius[3]
  }
  public var material: BackdropMaterialKind {
    get { BackdropMaterialKind(rawValue: _material) ?? .none }
    set { _material = newValue.rawValue }
  }
  public var blendingMode: BackdropBlendingMode {
    get { BackdropBlendingMode(rawValue: _blendingMode) ?? .none }
    set { _blendingMode = newValue.rawValue }
  }
  public var state: BackdropState {
    get { BackdropState(rawValue: _state) ?? .active }
    set { _state = newValue.rawValue }
  }
  public var appearance: BackdropAppearance {
    get { BackdropAppearance(rawValue: _appearance) ?? .auto }
    set { _appearance = newValue.rawValue }
  }
  public var maskKind: BackdropMask {
    get { BackdropMask(rawValue: _maskKind) ?? .none }
    set { _maskKind = newValue.rawValue }
  }
  public var shapeKind: EffectShape {
    get { EffectShape(rawValue: _shapeKind) ?? .none }
    set { _shapeKind = newValue.rawValue }
  }
  public var shapeRect: SIMD4<Float> {
    get { SIMD4<Float>(_shapeRectX, _shapeRectY, _shapeRectW, _shapeRectH) }
    set {
      _shapeRectX = newValue[0]
      _shapeRectY = newValue[1]
      _shapeRectW = newValue[2]
      _shapeRectH = newValue[3]
    }
  }
  public var shapeRadius: SIMD4<Float> {
    get { SIMD4<Float>(_shapeRadiusTl, _shapeRadiusTr, _shapeRadiusBr, _shapeRadiusBl) }
    set {
      _shapeRadiusTl = newValue[0]
      _shapeRadiusTr = newValue[1]
      _shapeRadiusBr = newValue[2]
      _shapeRadiusBl = newValue[3]
    }
  }
}

public struct LayerContent: Swift.Equatable, Swift.Sendable {
  public var _kind: Swift.UInt32
  public var handle: Swift.UInt64
  public init(kind: ContentKind = .none, handle: Swift.UInt64 = Swift.UInt64()) {
    self._kind = kind.rawValue
    self.handle = handle
  }
  public var kind: ContentKind {
    get { ContentKind(rawValue: _kind) ?? .none }
    set { _kind = newValue.rawValue }
  }
}

public struct ContentSample: Swift.Equatable, Swift.Sendable {
  public var sourceSurfaceId: Swift.UInt64
  public var srcX: Swift.Float
  public var srcY: Swift.Float
  public var srcW: Swift.Float
  public var srcH: Swift.Float
  public var logicalW: Swift.Float
  public var logicalH: Swift.Float
  public var opaqueFullSurface: Swift.Bool
  public var reserved0: Swift.UInt8
  public var reserved1: Swift.UInt16
  public init(sourceSurfaceId: Swift.UInt64 = Swift.UInt64(), srcX: Swift.Float = 0, srcY: Swift.Float = 0, srcW: Swift.Float = 0, srcH: Swift.Float = 0, logicalW: Swift.Float = 0, logicalH: Swift.Float = 0, opaqueFullSurface: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8(), reserved1: Swift.UInt16 = Swift.UInt16()) {
    self.sourceSurfaceId = sourceSurfaceId
    self.srcX = srcX
    self.srcY = srcY
    self.srcW = srcW
    self.srcH = srcH
    self.logicalW = logicalW
    self.logicalH = logicalH
    self.opaqueFullSurface = opaqueFullSurface
    self.reserved0 = reserved0
    self.reserved1 = reserved1
  }
}

public struct BackgroundEffectRegions: Swift.Equatable, Swift.Sendable {
  public var count: Swift.UInt32
  public var wholeSurface: Swift.Bool
  public var reserved0: Swift.UInt8
  public var reserved1: Swift.UInt16
  public var rect0X: Swift.Float
  public var rect0Y: Swift.Float
  public var rect0W: Swift.Float
  public var rect0H: Swift.Float
  public var rect1X: Swift.Float
  public var rect1Y: Swift.Float
  public var rect1W: Swift.Float
  public var rect1H: Swift.Float
  public var rect2X: Swift.Float
  public var rect2Y: Swift.Float
  public var rect2W: Swift.Float
  public var rect2H: Swift.Float
  public var rect3X: Swift.Float
  public var rect3Y: Swift.Float
  public var rect3W: Swift.Float
  public var rect3H: Swift.Float
  public var rect4X: Swift.Float
  public var rect4Y: Swift.Float
  public var rect4W: Swift.Float
  public var rect4H: Swift.Float
  public var rect5X: Swift.Float
  public var rect5Y: Swift.Float
  public var rect5W: Swift.Float
  public var rect5H: Swift.Float
  public var rect6X: Swift.Float
  public var rect6Y: Swift.Float
  public var rect6W: Swift.Float
  public var rect6H: Swift.Float
  public var rect7X: Swift.Float
  public var rect7Y: Swift.Float
  public var rect7W: Swift.Float
  public var rect7H: Swift.Float
  public init(count: Swift.UInt32 = Swift.UInt32(), wholeSurface: Swift.Bool = false, reserved0: Swift.UInt8 = Swift.UInt8(), reserved1: Swift.UInt16 = Swift.UInt16(), rect0X: Swift.Float = 0, rect0Y: Swift.Float = 0, rect0W: Swift.Float = 0, rect0H: Swift.Float = 0, rect1X: Swift.Float = 0, rect1Y: Swift.Float = 0, rect1W: Swift.Float = 0, rect1H: Swift.Float = 0, rect2X: Swift.Float = 0, rect2Y: Swift.Float = 0, rect2W: Swift.Float = 0, rect2H: Swift.Float = 0, rect3X: Swift.Float = 0, rect3Y: Swift.Float = 0, rect3W: Swift.Float = 0, rect3H: Swift.Float = 0, rect4X: Swift.Float = 0, rect4Y: Swift.Float = 0, rect4W: Swift.Float = 0, rect4H: Swift.Float = 0, rect5X: Swift.Float = 0, rect5Y: Swift.Float = 0, rect5W: Swift.Float = 0, rect5H: Swift.Float = 0, rect6X: Swift.Float = 0, rect6Y: Swift.Float = 0, rect6W: Swift.Float = 0, rect6H: Swift.Float = 0, rect7X: Swift.Float = 0, rect7Y: Swift.Float = 0, rect7W: Swift.Float = 0, rect7H: Swift.Float = 0) {
    self.count = count
    self.wholeSurface = wholeSurface
    self.reserved0 = reserved0
    self.reserved1 = reserved1
    self.rect0X = rect0X
    self.rect0Y = rect0Y
    self.rect0W = rect0W
    self.rect0H = rect0H
    self.rect1X = rect1X
    self.rect1Y = rect1Y
    self.rect1W = rect1W
    self.rect1H = rect1H
    self.rect2X = rect2X
    self.rect2Y = rect2Y
    self.rect2W = rect2W
    self.rect2H = rect2H
    self.rect3X = rect3X
    self.rect3Y = rect3Y
    self.rect3W = rect3W
    self.rect3H = rect3H
    self.rect4X = rect4X
    self.rect4Y = rect4Y
    self.rect4W = rect4W
    self.rect4H = rect4H
    self.rect5X = rect5X
    self.rect5Y = rect5Y
    self.rect5W = rect5W
    self.rect5H = rect5H
    self.rect6X = rect6X
    self.rect6Y = rect6Y
    self.rect6W = rect6W
    self.rect6H = rect6H
    self.rect7X = rect7X
    self.rect7Y = rect7Y
    self.rect7W = rect7W
    self.rect7H = rect7H
  }
}

public struct LayerDescriptor: Swift.Equatable, Swift.Sendable {
  public var layerId: Swift.UInt64
  public var _kind: Swift.UInt32
  public var reserved: Swift.UInt32
  public var frame: NucleusTypes.Rect
  public var opacity: Swift.Double
  public var hidden: Swift.Bool
  public var _role: Swift.UInt8
  public var reserved1: Swift.UInt16
  public var reserved2: Swift.UInt32
  public var backdropGroupId: Swift.UInt64
  public var visualEffect: NucleusTypes.VisualEffect
  public var targetContextId: Swift.UInt32
  public var reserved3: Swift.UInt32
  public init(layerId: Swift.UInt64 = Swift.UInt64(), kind: LayerKind = .none, reserved: Swift.UInt32 = Swift.UInt32(), frame: NucleusTypes.Rect = NucleusTypes.Rect(), opacity: Swift.Double = 0, hidden: Swift.Bool = false, role: LayerRole = .generic, reserved1: Swift.UInt16 = Swift.UInt16(), reserved2: Swift.UInt32 = Swift.UInt32(), backdropGroupId: Swift.UInt64 = Swift.UInt64(), visualEffect: NucleusTypes.VisualEffect = NucleusTypes.VisualEffect(), targetContextId: Swift.UInt32 = Swift.UInt32(), reserved3: Swift.UInt32 = Swift.UInt32()) {
    self.layerId = layerId
    self._kind = kind.rawValue
    self.reserved = reserved
    self.frame = frame
    self.opacity = opacity
    self.hidden = hidden
    self._role = role.rawValue
    self.reserved1 = reserved1
    self.reserved2 = reserved2
    self.backdropGroupId = backdropGroupId
    self.visualEffect = visualEffect
    self.targetContextId = targetContextId
    self.reserved3 = reserved3
  }
  public var kind: LayerKind {
    get { LayerKind(rawValue: _kind) ?? .none }
    set { _kind = newValue.rawValue }
  }
  public var role: LayerRole {
    get { LayerRole(rawValue: _role) ?? .generic }
    set { _role = newValue.rawValue }
  }
}

public struct Shadow: Swift.Equatable, Swift.Sendable {
  public var offsetX: Swift.Double
  public var offsetY: Swift.Double
  public var blurRadius: Swift.Double
  public var cornerRadius: Swift.Double
  public var opacity: Swift.Double
  public var color: NucleusTypes.Color
  public init(offsetX: Swift.Double = 0, offsetY: Swift.Double = 0, blurRadius: Swift.Double = 0, cornerRadius: Swift.Double = 0, opacity: Swift.Double = 0, color: NucleusTypes.Color = NucleusTypes.Color()) {
    self.offsetX = offsetX
    self.offsetY = offsetY
    self.blurRadius = blurRadius
    self.cornerRadius = cornerRadius
    self.opacity = opacity
    self.color = color
  }
}

public struct LayerPropertyUpdate: Swift.Equatable, Swift.Sendable {
  public var mask: Swift.UInt64
  public var opacity: Swift.Double
  public var hidden: Swift.Bool
  public var _actionPolicy: Swift.UInt8
  public var _foregroundVibrancy: Swift.UInt8
  public var backgroundEffect: Swift.Bool
  public var reserved2: Swift.UInt32
  public var backdropGroupId: Swift.UInt64
  public var visualEffect: NucleusTypes.VisualEffect
  public var shadow: NucleusTypes.Shadow
  public var position: NucleusTypes.Point
  public var bounds: NucleusTypes.Size
  public var anchorPoint: NucleusTypes.Point
  public var scrollOffset: NucleusTypes.Point
  public var transform: NucleusTypes.Transform
  public var clip: NucleusTypes.ClipOp
  public var cornerRadiusTl: Swift.Float
  public var cornerRadiusTr: Swift.Float
  public var cornerRadiusBr: Swift.Float
  public var cornerRadiusBl: Swift.Float
  public var borderTop: NucleusTypes.BorderEdge
  public var borderRight: NucleusTypes.BorderEdge
  public var borderBottom: NucleusTypes.BorderEdge
  public var borderLeft: NucleusTypes.BorderEdge
  public var content: NucleusTypes.LayerContent
  public var contentSample: NucleusTypes.ContentSample
  public var backgroundEffectRegions: NucleusTypes.BackgroundEffectRegions
  public var contentDamage: NucleusTypes.Rect
  public init(mask: Swift.UInt64 = Swift.UInt64(), opacity: Swift.Double = 0, hidden: Swift.Bool = false, actionPolicy: ActionPolicy = .none, foregroundVibrancy: ForegroundVibrancyMode = .inherit, backgroundEffect: Swift.Bool = false, reserved2: Swift.UInt32 = Swift.UInt32(), backdropGroupId: Swift.UInt64 = Swift.UInt64(), visualEffect: NucleusTypes.VisualEffect = NucleusTypes.VisualEffect(), shadow: NucleusTypes.Shadow = NucleusTypes.Shadow(), position: NucleusTypes.Point = NucleusTypes.Point(), bounds: NucleusTypes.Size = NucleusTypes.Size(), anchorPoint: NucleusTypes.Point = NucleusTypes.Point(), scrollOffset: NucleusTypes.Point = NucleusTypes.Point(), transform: NucleusTypes.Transform = NucleusTypes.Transform(), clip: NucleusTypes.ClipOp = NucleusTypes.ClipOp(), cornerRadiusTl: Swift.Float = 0, cornerRadiusTr: Swift.Float = 0, cornerRadiusBr: Swift.Float = 0, cornerRadiusBl: Swift.Float = 0, borderTop: NucleusTypes.BorderEdge = NucleusTypes.BorderEdge(), borderRight: NucleusTypes.BorderEdge = NucleusTypes.BorderEdge(), borderBottom: NucleusTypes.BorderEdge = NucleusTypes.BorderEdge(), borderLeft: NucleusTypes.BorderEdge = NucleusTypes.BorderEdge(), content: NucleusTypes.LayerContent = NucleusTypes.LayerContent(), contentSample: NucleusTypes.ContentSample = NucleusTypes.ContentSample(), backgroundEffectRegions: NucleusTypes.BackgroundEffectRegions = NucleusTypes.BackgroundEffectRegions(), contentDamage: NucleusTypes.Rect = NucleusTypes.Rect()) {
    self.mask = mask
    self.opacity = opacity
    self.hidden = hidden
    self._actionPolicy = actionPolicy.rawValue
    self._foregroundVibrancy = foregroundVibrancy.rawValue
    self.backgroundEffect = backgroundEffect
    self.reserved2 = reserved2
    self.backdropGroupId = backdropGroupId
    self.visualEffect = visualEffect
    self.shadow = shadow
    self.position = position
    self.bounds = bounds
    self.anchorPoint = anchorPoint
    self.scrollOffset = scrollOffset
    self.transform = transform
    self.clip = clip
    self.cornerRadiusTl = cornerRadiusTl
    self.cornerRadiusTr = cornerRadiusTr
    self.cornerRadiusBr = cornerRadiusBr
    self.cornerRadiusBl = cornerRadiusBl
    self.borderTop = borderTop
    self.borderRight = borderRight
    self.borderBottom = borderBottom
    self.borderLeft = borderLeft
    self.content = content
    self.contentSample = contentSample
    self.backgroundEffectRegions = backgroundEffectRegions
    self.contentDamage = contentDamage
  }
  public var actionPolicy: ActionPolicy {
    get { ActionPolicy(rawValue: _actionPolicy) ?? .none }
    set { _actionPolicy = newValue.rawValue }
  }
  public var foregroundVibrancy: ForegroundVibrancyMode {
    get { ForegroundVibrancyMode(rawValue: _foregroundVibrancy) ?? .inherit }
    set { _foregroundVibrancy = newValue.rawValue }
  }
}

public struct LayerCreatedRecord: Swift.Equatable, Swift.Sendable {
  public var nodeId: Swift.UInt64
  public var _kind: Swift.UInt32
  public var reserved: Swift.UInt32
  public var frame: NucleusTypes.Rect
  public var opacity: Swift.Double
  public var hidden: Swift.Bool
  public var _role: Swift.UInt8
  public var reserved1: Swift.UInt16
  public var reserved2: Swift.UInt32
  public var backdropGroupId: Swift.UInt64
  public var visualEffect: NucleusTypes.VisualEffect
  public var targetContextId: Swift.UInt32
  public var reserved3: Swift.UInt32
  public var initialContent: NucleusTypes.LayerContent
  public init(nodeId: Swift.UInt64 = Swift.UInt64(), kind: LayerKind = .none, reserved: Swift.UInt32 = Swift.UInt32(), frame: NucleusTypes.Rect = NucleusTypes.Rect(), opacity: Swift.Double = 0, hidden: Swift.Bool = false, role: LayerRole = .generic, reserved1: Swift.UInt16 = Swift.UInt16(), reserved2: Swift.UInt32 = Swift.UInt32(), backdropGroupId: Swift.UInt64 = Swift.UInt64(), visualEffect: NucleusTypes.VisualEffect = NucleusTypes.VisualEffect(), targetContextId: Swift.UInt32 = Swift.UInt32(), reserved3: Swift.UInt32 = Swift.UInt32(), initialContent: NucleusTypes.LayerContent = NucleusTypes.LayerContent()) {
    self.nodeId = nodeId
    self._kind = kind.rawValue
    self.reserved = reserved
    self.frame = frame
    self.opacity = opacity
    self.hidden = hidden
    self._role = role.rawValue
    self.reserved1 = reserved1
    self.reserved2 = reserved2
    self.backdropGroupId = backdropGroupId
    self.visualEffect = visualEffect
    self.targetContextId = targetContextId
    self.reserved3 = reserved3
    self.initialContent = initialContent
  }
  public var kind: LayerKind {
    get { LayerKind(rawValue: _kind) ?? .none }
    set { _kind = newValue.rawValue }
  }
  public var role: LayerRole {
    get { LayerRole(rawValue: _role) ?? .generic }
    set { _role = newValue.rawValue }
  }
}

public struct LayerInsertRecord: Swift.Equatable, Swift.Sendable {
  public var nodeId: Swift.UInt64
  public var parentId: Swift.UInt64
  public var index: Swift.UInt32
  public var reserved: Swift.UInt32
  public init(nodeId: Swift.UInt64 = Swift.UInt64(), parentId: Swift.UInt64 = Swift.UInt64(), index: Swift.UInt32 = Swift.UInt32(), reserved: Swift.UInt32 = Swift.UInt32()) {
    self.nodeId = nodeId
    self.parentId = parentId
    self.index = index
    self.reserved = reserved
  }
}

public struct LayerRemoveRecord: Swift.Equatable, Swift.Sendable {
  public var nodeId: Swift.UInt64
  public init(nodeId: Swift.UInt64 = Swift.UInt64()) {
    self.nodeId = nodeId
  }
}

public struct LayerDetachRecord: Swift.Equatable, Swift.Sendable {
  public var nodeId: Swift.UInt64
  public init(nodeId: Swift.UInt64 = Swift.UInt64()) {
    self.nodeId = nodeId
  }
}

public struct LayerPropertyRecord: Swift.Equatable, Swift.Sendable {
  public var nodeId: Swift.UInt64
  public var properties: NucleusTypes.LayerPropertyUpdate
  public init(nodeId: Swift.UInt64 = Swift.UInt64(), properties: NucleusTypes.LayerPropertyUpdate = NucleusTypes.LayerPropertyUpdate()) {
    self.nodeId = nodeId
    self.properties = properties
  }
}

public struct AnimationCurve: Swift.Equatable, Swift.Sendable {
  public var _kind: Swift.UInt32
  public var reserved: Swift.UInt32
  public var bezierP1x: Swift.Float
  public var bezierP1y: Swift.Float
  public var bezierP2x: Swift.Float
  public var bezierP2y: Swift.Float
  public var springStiffness: Swift.Float
  public var springDamping: Swift.Float
  public var springMass: Swift.Float
  public var springInitialVelocity: Swift.Float
  public init(kind: AnimationCurveKind = .linear, reserved: Swift.UInt32 = Swift.UInt32(), bezierP1x: Swift.Float = 0, bezierP1y: Swift.Float = 0, bezierP2x: Swift.Float = 0, bezierP2y: Swift.Float = 0, springStiffness: Swift.Float = 0, springDamping: Swift.Float = 0, springMass: Swift.Float = 0, springInitialVelocity: Swift.Float = 0) {
    self._kind = kind.rawValue
    self.reserved = reserved
    self.bezierP1x = bezierP1x
    self.bezierP1y = bezierP1y
    self.bezierP2x = bezierP2x
    self.bezierP2y = bezierP2y
    self.springStiffness = springStiffness
    self.springDamping = springDamping
    self.springMass = springMass
    self.springInitialVelocity = springInitialVelocity
  }
  public var kind: AnimationCurveKind {
    get { AnimationCurveKind(rawValue: _kind) ?? .linear }
    set { _kind = newValue.rawValue }
  }
}

public struct AnimationEndpoint: Swift.Equatable, Swift.Sendable {
  public var scalar: Swift.Double
  public var point: NucleusTypes.Point
  public var size: NucleusTypes.Size
  public var rect: NucleusTypes.Rect
  public var transform: NucleusTypes.Transform
  public init(scalar: Swift.Double = 0, point: NucleusTypes.Point = NucleusTypes.Point(), size: NucleusTypes.Size = NucleusTypes.Size(), rect: NucleusTypes.Rect = NucleusTypes.Rect(), transform: NucleusTypes.Transform = NucleusTypes.Transform()) {
    self.scalar = scalar
    self.point = point
    self.size = size
    self.rect = rect
    self.transform = transform
  }
}

public struct AnimationRecord: Swift.Equatable, Swift.Sendable {
  public var nodeId: Swift.UInt64
  public var animationId: Swift.UInt64
  public var completionToken: Swift.UInt64
  public var _keyPath: Swift.UInt32
  public var reserved: Swift.UInt32
  public var duration: Swift.Double
  public var fromEndpoint: NucleusTypes.AnimationEndpoint
  public var toEndpoint: NucleusTypes.AnimationEndpoint
  public var curve: NucleusTypes.AnimationCurve
  public init(nodeId: Swift.UInt64 = Swift.UInt64(), animationId: Swift.UInt64 = Swift.UInt64(), completionToken: Swift.UInt64 = Swift.UInt64(), keyPath: AnimationKeyPath = .none, reserved: Swift.UInt32 = Swift.UInt32(), duration: Swift.Double = 0, fromEndpoint: NucleusTypes.AnimationEndpoint = NucleusTypes.AnimationEndpoint(), toEndpoint: NucleusTypes.AnimationEndpoint = NucleusTypes.AnimationEndpoint(), curve: NucleusTypes.AnimationCurve = NucleusTypes.AnimationCurve()) {
    self.nodeId = nodeId
    self.animationId = animationId
    self.completionToken = completionToken
    self._keyPath = keyPath.rawValue
    self.reserved = reserved
    self.duration = duration
    self.fromEndpoint = fromEndpoint
    self.toEndpoint = toEndpoint
    self.curve = curve
  }
  public var keyPath: AnimationKeyPath {
    get { AnimationKeyPath(rawValue: _keyPath) ?? .none }
    set { _keyPath = newValue.rawValue }
  }
}

public struct AnimationRemoveRecord: Swift.Equatable, Swift.Sendable {
  public var nodeId: Swift.UInt64
  public var _keyPath: Swift.UInt32
  public var reserved: Swift.UInt32
  public init(nodeId: Swift.UInt64 = Swift.UInt64(), keyPath: AnimationKeyPath = .none, reserved: Swift.UInt32 = Swift.UInt32()) {
    self.nodeId = nodeId
    self._keyPath = keyPath.rawValue
    self.reserved = reserved
  }
  public var keyPath: AnimationKeyPath {
    get { AnimationKeyPath(rawValue: _keyPath) ?? .none }
    set { _keyPath = newValue.rawValue }
  }
}

/// One paint draw command. Passed as a `Span` between Swift modules in the
/// same process — there is no serialization and no second implementation, so
/// `kind` is stored as the enum itself rather than a raw discriminant plus a
/// lossy accessor.
///
/// Variable-length data (path verbs/points, gradient stops, effect uniforms)
/// is not inlined here: it rides a parallel payload blob at
/// `payloadOffset ..< payloadOffset + payloadLength`. That split is by
/// *lifetime* — per-frame data goes in the blob, while stable expensive
/// resources (images, text layouts, compiled SkSL) keep handle registrars.
public struct PaintCommand: Swift.Equatable, Swift.Sendable {
  public var kind: PaintCommandKind
  public var flags: PaintCommandFlags
  public var shading: PaintShading
  public var blend: PaintBlendMode
  public var x: Swift.Float
  public var y: Swift.Float
  public var w: Swift.Float
  public var h: Swift.Float
  public var radius: Swift.Float
  public var strokeWidth: Swift.Float
  public var fontSize: Swift.Float
  public var alpha: Swift.Float
  public var blurSigma: Swift.Float
  public var saturation: Swift.Float
  public var color: NucleusTypes.Color
  public var imageHandle: Swift.UInt64
  public var textLayoutHandle: Swift.UInt64
  public var effectHandle: Swift.UInt64
  public var payloadOffset: Swift.UInt32
  public var payloadLength: Swift.UInt32
  /// An affine transform (a, b, c, d, tx, ty), meaningful only with
  /// `.hasTransform`. Geometry remains local and the renderer composes this
  /// matrix with backing scale.
  public var transformA: Swift.Float
  public var transformB: Swift.Float
  public var transformC: Swift.Float
  public var transformD: Swift.Float
  public var transformTX: Swift.Float
  public var transformTY: Swift.Float

  public init(
    kind: PaintCommandKind,
    flags: PaintCommandFlags = .default,
    shading: PaintShading = .color,
    blend: PaintBlendMode = .srcOver,
    x: Swift.Float = 0, y: Swift.Float = 0, w: Swift.Float = 0, h: Swift.Float = 0,
    radius: Swift.Float = 0, strokeWidth: Swift.Float = 0, fontSize: Swift.Float = 0,
    alpha: Swift.Float = 1, blurSigma: Swift.Float = 0, saturation: Swift.Float = 1,
    color: NucleusTypes.Color = NucleusTypes.Color(r: 1, g: 1, b: 1, a: 1),
    imageHandle: Swift.UInt64 = Swift.UInt64(),
    textLayoutHandle: Swift.UInt64 = Swift.UInt64(),
    effectHandle: Swift.UInt64 = Swift.UInt64(),
    payloadOffset: Swift.UInt32 = 0, payloadLength: Swift.UInt32 = 0,
    transformA: Swift.Float = 1, transformB: Swift.Float = 0,
    transformC: Swift.Float = 0, transformD: Swift.Float = 1,
    transformTX: Swift.Float = 0, transformTY: Swift.Float = 0
  ) {
    self.kind = kind
    self.flags = flags
    self.shading = shading
    self.blend = blend
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.radius = radius
    self.strokeWidth = strokeWidth
    self.fontSize = fontSize
    self.alpha = alpha
    self.blurSigma = blurSigma
    self.saturation = saturation
    self.color = color
    self.imageHandle = imageHandle
    self.textLayoutHandle = textLayoutHandle
    self.effectHandle = effectHandle
    self.payloadOffset = payloadOffset
    self.payloadLength = payloadLength
    self.transformA = transformA
    self.transformB = transformB
    self.transformC = transformC
    self.transformD = transformD
    self.transformTX = transformTX
    self.transformTY = transformTY
  }
}

extension PaintCommandFlags: Swift.Equatable {}
