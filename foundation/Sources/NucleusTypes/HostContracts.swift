import Swift

// MARK: - Stable host identities

public struct SurfaceID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct OutputID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct SeatID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct DeviceID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct BufferID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct InputSequenceID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

// MARK: - Output and presentation values

public enum OutputTransform: UInt8, Sendable, CaseIterable {
    case normal
    case rotate90
    case rotate180
    case rotate270
    case flipped
    case flipped90
    case flipped180
    case flipped270
}

public struct OutputScale: Equatable, Sendable {
    public var pointsToPixels: Double

    public init(pointsToPixels: Double) {
        precondition(pointsToPixels.isFinite && pointsToPixels > 0)
        self.pointsToPixels = pointsToPixels
    }

    public static let one = OutputScale(pointsToPixels: 1)
}

public struct RefreshRate: Equatable, Sendable {
    public var millihertz: UInt32

    public init(millihertz: UInt32) {
        precondition(millihertz > 0)
        self.millihertz = millihertz
    }
}

public enum ColorPrimaries: UInt8, Sendable {
    case sRGB
    case displayP3
    case rec2020
}

public enum TransferFunction: UInt8, Sendable {
    case sRGB
    case linear
    case perceptualQuantizer
    case hybridLogGamma
}

public struct ColorDescription: Equatable, Sendable {
    public var primaries: ColorPrimaries
    public var transferFunction: TransferFunction

    public init(
        primaries: ColorPrimaries = .sRGB,
        transferFunction: TransferFunction = .sRGB
    ) {
        self.primaries = primaries
        self.transferFunction = transferFunction
    }
}

public struct OutputDescriptor: Equatable, Sendable {
    public var id: OutputID
    public var name: String
    public var logicalFrame: GlobalLogicalRect
    public var pixelSize: OutputPixelSize
    public var scale: OutputScale
    public var transform: OutputTransform
    public var refreshRate: RefreshRate
    public var color: ColorDescription

    public init(
        id: OutputID,
        name: String,
        logicalFrame: GlobalLogicalRect,
        pixelSize: OutputPixelSize,
        scale: OutputScale,
        transform: OutputTransform = .normal,
        refreshRate: RefreshRate,
        color: ColorDescription = ColorDescription()
    ) {
        self.id = id
        self.name = name
        self.logicalFrame = logicalFrame
        self.pixelSize = pixelSize
        self.scale = scale
        self.transform = transform
        self.refreshRate = refreshRate
        self.color = color
    }
}

public struct DamageRegion: Equatable, Sendable {
    public var rects: [OutputPixelRect]
    public init(rects: [OutputPixelRect] = []) { self.rects = rects }
}

public struct PresentationTimestamp: Equatable, Sendable {
    public var monotonicNanoseconds: UInt64
    public var refreshIntervalNanoseconds: UInt64

    public init(
        monotonicNanoseconds: UInt64,
        refreshIntervalNanoseconds: UInt64
    ) {
        self.monotonicNanoseconds = monotonicNanoseconds
        self.refreshIntervalNanoseconds = refreshIntervalNanoseconds
    }
}

public struct SynchronizationToken: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct PresentationCapabilities: OptionSet, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let explicitSynchronization =
        PresentationCapabilities(rawValue: 1 << 0)
    public static let incrementalPresent =
        PresentationCapabilities(rawValue: 1 << 1)
    public static let variableRefreshRate =
        PresentationCapabilities(rawValue: 1 << 2)
    public static let wideColor = PresentationCapabilities(rawValue: 1 << 3)
    public static let hdr = PresentationCapabilities(rawValue: 1 << 4)
}

// MARK: - Role-neutral application input

public enum InputEventKind: UInt8, Sendable, Equatable {
    case pointerEnter
    case pointerLeave
    case pointerMotion
    case pointerButtonDown
    case pointerButtonUp
    case pointerAxis
    case keyDown
    case keyUp
    case keyboardEnter
    case keyboardLeave
    case touchDown
    case touchMotion
    case touchUp
    case touchCancel
    case tabletToolEnter
    case tabletToolLeave
    case tabletToolMotion
    case tabletToolButtonDown
    case tabletToolButtonUp
    case focusGained
    case focusLost
    case textPreedit
    case textCommit
}

public struct InputModifierFlags: OptionSet, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = InputModifierFlags(rawValue: 1 << 0)
    public static let control = InputModifierFlags(rawValue: 1 << 1)
    public static let option = InputModifierFlags(rawValue: 1 << 2)
    public static let command = InputModifierFlags(rawValue: 1 << 3)
    public static let capsLock = InputModifierFlags(rawValue: 1 << 4)
    public static let numericPad = InputModifierFlags(rawValue: 1 << 5)
    public static let function = InputModifierFlags(rawValue: 1 << 6)
}

public struct PointerButtonCode: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let left = PointerButtonCode(rawValue: 0)
    public static let right = PointerButtonCode(rawValue: 1)
    public static let middle = PointerButtonCode(rawValue: 2)
    public static let back = PointerButtonCode(rawValue: 3)
    public static let forward = PointerButtonCode(rawValue: 4)
}

public struct PointerButtonSet: OptionSet, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static func button(_ button: PointerButtonCode) -> PointerButtonSet {
        guard button.rawValue < 64 else { return [] }
        return PointerButtonSet(rawValue: 1 << button.rawValue)
    }
}

public enum PointerToolKind: UInt8, Sendable, Equatable {
    case unknown
    case mouse
    case finger
    case stylus
    case eraser
}

public struct PhysicalKey: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let unknown = PhysicalKey(rawValue: 0)
    public static let escape = PhysicalKey(rawValue: 1)
    public static let `return` = PhysicalKey(rawValue: 2)
    public static let tab = PhysicalKey(rawValue: 3)
    public static let space = PhysicalKey(rawValue: 4)
    public static let delete = PhysicalKey(rawValue: 5)
    public static let forwardDelete = PhysicalKey(rawValue: 6)
    public static let insert = PhysicalKey(rawValue: 7)
    public static let leftArrow = PhysicalKey(rawValue: 10)
    public static let rightArrow = PhysicalKey(rawValue: 11)
    public static let upArrow = PhysicalKey(rawValue: 12)
    public static let downArrow = PhysicalKey(rawValue: 13)
    public static let home = PhysicalKey(rawValue: 14)
    public static let end = PhysicalKey(rawValue: 15)
    public static let pageUp = PhysicalKey(rawValue: 16)
    public static let pageDown = PhysicalKey(rawValue: 17)

    public static let letterA = PhysicalKey(rawValue: 100)
    public static let letterB = PhysicalKey(rawValue: 101)
    public static let letterC = PhysicalKey(rawValue: 102)
    public static let letterD = PhysicalKey(rawValue: 103)
    public static let letterE = PhysicalKey(rawValue: 104)
    public static let letterF = PhysicalKey(rawValue: 105)
    public static let letterG = PhysicalKey(rawValue: 106)
    public static let letterH = PhysicalKey(rawValue: 107)
    public static let letterI = PhysicalKey(rawValue: 108)
    public static let letterJ = PhysicalKey(rawValue: 109)
    public static let letterK = PhysicalKey(rawValue: 110)
    public static let letterL = PhysicalKey(rawValue: 111)
    public static let letterM = PhysicalKey(rawValue: 112)
    public static let letterN = PhysicalKey(rawValue: 113)
    public static let letterO = PhysicalKey(rawValue: 114)
    public static let letterP = PhysicalKey(rawValue: 115)
    public static let letterQ = PhysicalKey(rawValue: 116)
    public static let letterR = PhysicalKey(rawValue: 117)
    public static let letterS = PhysicalKey(rawValue: 118)
    public static let letterT = PhysicalKey(rawValue: 119)
    public static let letterU = PhysicalKey(rawValue: 120)
    public static let letterV = PhysicalKey(rawValue: 121)
    public static let letterW = PhysicalKey(rawValue: 122)
    public static let letterX = PhysicalKey(rawValue: 123)
    public static let letterY = PhysicalKey(rawValue: 124)
    public static let letterZ = PhysicalKey(rawValue: 125)

    public static let digit0 = PhysicalKey(rawValue: 130)
    public static let digit1 = PhysicalKey(rawValue: 131)
    public static let digit2 = PhysicalKey(rawValue: 132)
    public static let digit3 = PhysicalKey(rawValue: 133)
    public static let digit4 = PhysicalKey(rawValue: 134)
    public static let digit5 = PhysicalKey(rawValue: 135)
    public static let digit6 = PhysicalKey(rawValue: 136)
    public static let digit7 = PhysicalKey(rawValue: 137)
    public static let digit8 = PhysicalKey(rawValue: 138)
    public static let digit9 = PhysicalKey(rawValue: 139)

    public static let minus = PhysicalKey(rawValue: 150)
    public static let equal = PhysicalKey(rawValue: 151)
    public static let leftBracket = PhysicalKey(rawValue: 152)
    public static let rightBracket = PhysicalKey(rawValue: 153)
    public static let backslash = PhysicalKey(rawValue: 154)
    public static let semicolon = PhysicalKey(rawValue: 155)
    public static let quote = PhysicalKey(rawValue: 156)
    public static let grave = PhysicalKey(rawValue: 157)
    public static let comma = PhysicalKey(rawValue: 158)
    public static let period = PhysicalKey(rawValue: 159)
    public static let slash = PhysicalKey(rawValue: 160)

    public static let f1 = PhysicalKey(rawValue: 170)
    public static let f2 = PhysicalKey(rawValue: 171)
    public static let f3 = PhysicalKey(rawValue: 172)
    public static let f4 = PhysicalKey(rawValue: 173)
    public static let f5 = PhysicalKey(rawValue: 174)
    public static let f6 = PhysicalKey(rawValue: 175)
    public static let f7 = PhysicalKey(rawValue: 176)
    public static let f8 = PhysicalKey(rawValue: 177)
    public static let f9 = PhysicalKey(rawValue: 178)
    public static let f10 = PhysicalKey(rawValue: 179)
    public static let f11 = PhysicalKey(rawValue: 180)
    public static let f12 = PhysicalKey(rawValue: 181)

    public init(linuxEvdevCode code: UInt32) {
        self = PhysicalKey.linuxEvdevTable[code] ?? .unknown
    }

    private static let linuxEvdevTable: [UInt32: PhysicalKey] = [
        1: .escape, 14: .delete, 15: .tab, 28: .return, 96: .return, 57: .space,
        110: .insert, 111: .forwardDelete,
        102: .home, 103: .upArrow, 104: .pageUp, 105: .leftArrow,
        106: .rightArrow, 107: .end, 108: .downArrow, 109: .pageDown,
        2: .digit1, 3: .digit2, 4: .digit3, 5: .digit4, 6: .digit5,
        7: .digit6, 8: .digit7, 9: .digit8, 10: .digit9, 11: .digit0,
        12: .minus, 13: .equal, 26: .leftBracket, 27: .rightBracket,
        43: .backslash, 39: .semicolon, 40: .quote, 41: .grave,
        51: .comma, 52: .period, 53: .slash,
        16: .letterQ, 17: .letterW, 18: .letterE, 19: .letterR, 20: .letterT,
        21: .letterY, 22: .letterU, 23: .letterI, 24: .letterO, 25: .letterP,
        30: .letterA, 31: .letterS, 32: .letterD, 33: .letterF, 34: .letterG,
        35: .letterH, 36: .letterJ, 37: .letterK, 38: .letterL,
        44: .letterZ, 45: .letterX, 46: .letterC, 47: .letterV, 48: .letterB,
        49: .letterN, 50: .letterM,
        59: .f1, 60: .f2, 61: .f3, 62: .f4, 63: .f5, 64: .f6,
        65: .f7, 66: .f8, 67: .f9, 68: .f10, 87: .f11, 88: .f12,
    ]
}

public enum InputScrollSource: UInt8, Sendable, Equatable {
    case unknown
    case wheel
    case finger
    case continuous
    case wheelTilt
}

public enum InputScrollPhase: UInt8, Sendable, Equatable {
    case none
    case began
    case changed
    case ended
    case cancelled
}

/// A process- and platform-neutral input record. Platform adapters resolve
/// native codes before constructing this value; UI adapters decide how to
/// deliver it into their responder model.
public struct ApplicationInputEvent: Sendable, Equatable {
    public var kind: InputEventKind
    public var surfaceID: SurfaceID?
    public var seatID: SeatID
    public var deviceID: DeviceID
    public var sequenceID: InputSequenceID
    public var location: Point
    public var timestampNanoseconds: UInt64
    public var modifiers: InputModifierFlags
    public var button: PointerButtonCode
    public var activeButtons: PointerButtonSet
    public var pointerTool: PointerToolKind
    public var pressure: Double
    public var scrollX: Double
    public var scrollY: Double
    public var scrollSource: InputScrollSource
    public var scrollDetentsX: Double
    public var scrollDetentsY: Double
    public var scrollPhase: InputScrollPhase
    public var key: PhysicalKey
    public var text: String?
    public var isRepeat: Bool

    public init(
        kind: InputEventKind,
        surfaceID: SurfaceID? = nil,
        seatID: SeatID = SeatID(rawValue: 0),
        deviceID: DeviceID = DeviceID(rawValue: 0),
        sequenceID: InputSequenceID = InputSequenceID(rawValue: 0),
        location: Point = Point(),
        timestampNanoseconds: UInt64 = 0,
        modifiers: InputModifierFlags = [],
        button: PointerButtonCode = .left,
        activeButtons: PointerButtonSet = [],
        pointerTool: PointerToolKind = .unknown,
        pressure: Double = 0,
        scrollX: Double = 0,
        scrollY: Double = 0,
        scrollSource: InputScrollSource = .unknown,
        scrollDetentsX: Double = 0,
        scrollDetentsY: Double = 0,
        scrollPhase: InputScrollPhase = .none,
        key: PhysicalKey = .unknown,
        text: String? = nil,
        isRepeat: Bool = false
    ) {
        self.kind = kind
        self.surfaceID = surfaceID
        self.seatID = seatID
        self.deviceID = deviceID
        self.sequenceID = sequenceID
        self.location = location
        self.timestampNanoseconds = timestampNanoseconds
        self.modifiers = modifiers
        self.button = button
        self.activeButtons = activeButtons
        self.pointerTool = pointerTool
        self.pressure = pressure.isFinite ? min(max(0, pressure), 1) : 0
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.scrollSource = scrollSource
        self.scrollDetentsX = scrollDetentsX
        self.scrollDetentsY = scrollDetentsY
        self.scrollPhase = scrollPhase
        self.key = key
        self.text = text
        self.isRepeat = isRepeat
    }
}

public enum WindowLifecycleEvent: UInt8, Sendable {
    case created
    case shown
    case hidden
    case focused
    case unfocused
    case closeRequested
    case destroyed
}

public struct WindowLifecycleUpdate: Sendable {
    public var surfaceID: SurfaceID
    public var event: WindowLifecycleEvent
    public var logicalFrame: SurfaceLogicalRect

    public init(
        surfaceID: SurfaceID,
        event: WindowLifecycleEvent,
        logicalFrame: SurfaceLogicalRect
    ) {
        self.surfaceID = surfaceID
        self.event = event
        self.logicalFrame = logicalFrame
    }
}

public enum RenderUploadKind: UInt8, Sendable {
    case image
    case pixels
    case paintCommands
    case runtimeEffect
}

public struct RenderUpload: Sendable {
    public var bufferID: BufferID
    public var kind: RenderUploadKind
    public var bytes: [UInt8]

    public init(bufferID: BufferID, kind: RenderUploadKind, bytes: [UInt8]) {
        self.bufferID = bufferID
        self.kind = kind
        self.bytes = bytes
    }
}
