import Swift

// The paint payload blob.
//
// A `PaintCommand` is fixed-size, so anything variable-length — path verbs and
// points, gradient stops, effect uniforms — rides a parallel byte blob and is
// addressed by `payloadOffset`/`payloadLength`. The split is by *lifetime*:
// this data is rebuilt every time a view draws and dies with the command list,
// so handle-minting it would mean thousands of retain/release round-trips per
// frame. Stable expensive resources (images, text layouts, compiled SkSL) keep
// their handle registrars instead.
//
// Encoder and decoder live together here because they are one format. Both the
// authoring side (`NucleusUI.GraphicsContext`) and the rasterizing side
// (`NucleusRenderer`) depend on `NucleusTypes`, so neither can drift from the
// other without this file changing.

/// How a draw's interior is filled. `.color` uses the command's `color`; the
/// rest read their parameters from the payload's scalar/color regions, and
/// `.effect` additionally uses the command's `effectHandle`.
public enum PaintShading: Swift.UInt32, Swift.Sendable {
  case color = 0
  case linearGradient = 1
  case radialGradient = 2
  case sweepGradient = 3
  case effect = 4
}

/// A path verb. Each consumes a fixed number of floats from the point region:
/// `move`/`line` two, `quad` four, `cubic` six, `arc` six (oval origin, oval
/// size, start/sweep angles in degrees), `close` none. Mirrors
/// `nucleus::skia::PathVerb`.
public enum PaintPathVerb: Swift.UInt8, Swift.Sendable {
  case move = 0
  case line = 1
  case quad = 2
  case cubic = 3
  case arc = 4
  case close = 5

  /// Floats this verb consumes from the point region.
  public var floatCount: Swift.Int {
    switch self {
    case .move, .line: 2
    case .quad: 4
    case .cubic, .arc: 6
    case .close: 0
    }
  }
}

/// Region sizes, written ahead of the regions themselves so a slice is
/// self-describing and can be validated without consulting the command.
///
/// Layout, in order, 4-byte aligned throughout:
///
///     u32 verbCount, u32 pointCount, u32 scalarCount, u32 colorCount
///     u8  verbs[verbCount]        (padded up to a 4-byte boundary)
///     f32 points[pointCount]
///     f32 scalars[scalarCount]    gradient geometry + stops, or effect uniforms
///     f32 colors[colorCount * 4]  gradient stop colors, RGBA
public struct PaintPayloadHeader: Swift.Equatable, Swift.Sendable {
  public var verbCount: Swift.UInt32
  public var pointCount: Swift.UInt32
  public var scalarCount: Swift.UInt32
  public var colorCount: Swift.UInt32

  public init(
    verbCount: Swift.UInt32 = 0, pointCount: Swift.UInt32 = 0,
    scalarCount: Swift.UInt32 = 0, colorCount: Swift.UInt32 = 0
  ) {
    self.verbCount = verbCount
    self.pointCount = pointCount
    self.scalarCount = scalarCount
    self.colorCount = colorCount
  }
}

public enum PaintPayload {
  public static let headerByteCount = 16

  static func alignUp4(_ n: Swift.Int) -> Swift.Int { (n + 3) & ~3 }

  /// Byte length of a slice with these region sizes.
  public static func byteCount(for header: PaintPayloadHeader) -> Swift.Int {
    headerByteCount
      + alignUp4(Swift.Int(header.verbCount))
      + Swift.Int(header.pointCount) * 4
      + Swift.Int(header.scalarCount) * 4
      + Swift.Int(header.colorCount) * 16
  }

  // MARK: - Encoding

  /// Append one command's variable-length data to `blob` and return the slice
  /// to record on the command. Appending is the only mutation, so offsets of
  /// already-written commands never move — which is what makes the command
  /// array's `==` a sound re-registration gate.
  @discardableResult
  public static func append(
    to blob: inout [Swift.UInt8],
    verbs: [PaintPathVerb] = [],
    points: [Swift.Float] = [],
    scalars: [Swift.Float] = [],
    colors: [Color] = []
  ) -> (offset: Swift.UInt32, length: Swift.UInt32) {
    let start = blob.count
    let header = PaintPayloadHeader(
      verbCount: Swift.UInt32(verbs.count),
      pointCount: Swift.UInt32(points.count),
      scalarCount: Swift.UInt32(scalars.count),
      colorCount: Swift.UInt32(colors.count))

    appendUInt32(&blob, header.verbCount)
    appendUInt32(&blob, header.pointCount)
    appendUInt32(&blob, header.scalarCount)
    appendUInt32(&blob, header.colorCount)

    for verb in verbs { blob.append(verb.rawValue) }
    while (blob.count - start - headerByteCount) % 4 != 0 { blob.append(0) }

    for value in points { appendFloat(&blob, value) }
    for value in scalars { appendFloat(&blob, value) }
    for color in colors {
      appendFloat(&blob, color.r)
      appendFloat(&blob, color.g)
      appendFloat(&blob, color.b)
      appendFloat(&blob, color.a)
    }
    return (Swift.UInt32(start), Swift.UInt32(blob.count - start))
  }

  static func appendUInt32(_ blob: inout [Swift.UInt8], _ value: Swift.UInt32) {
    blob.append(Swift.UInt8(truncatingIfNeeded: value))
    blob.append(Swift.UInt8(truncatingIfNeeded: value >> 8))
    blob.append(Swift.UInt8(truncatingIfNeeded: value >> 16))
    blob.append(Swift.UInt8(truncatingIfNeeded: value >> 24))
  }

  static func appendFloat(_ blob: inout [Swift.UInt8], _ value: Swift.Float) {
    appendUInt32(&blob, value.bitPattern)
  }

  // MARK: - Decoding

  /// One command's decoded variable-length data.
  public struct Regions: Swift.Equatable, Swift.Sendable {
    public var verbs: [PaintPathVerb]
    public var points: [Swift.Float]
    public var scalars: [Swift.Float]
    public var colors: [Color]

    public init(
      verbs: [PaintPathVerb] = [], points: [Swift.Float] = [],
      scalars: [Swift.Float] = [], colors: [Color] = []
    ) {
      self.verbs = verbs
      self.points = points
      self.scalars = scalars
      self.colors = colors
    }
  }

  /// Decode the slice `offset ..< offset + length` of `blob`.
  ///
  /// Returns nil when the slice is out of bounds, when the declared regions do
  /// not add up to the declared length, or when a verb is unknown or consumes
  /// more points than were supplied. A malformed payload is a producer bug, and
  /// failing here surfaces it as a missing draw rather than as arbitrary
  /// geometry built from misread bytes.
  public static func decode(
    _ blob: [Swift.UInt8], offset: Swift.UInt32, length: Swift.UInt32
  ) -> Regions? {
    let start = Swift.Int(offset)
    let end = start + Swift.Int(length)
    guard length >= headerByteCount, start >= 0, end <= blob.count else { return nil }

    let header = PaintPayloadHeader(
      verbCount: readUInt32(blob, start),
      pointCount: readUInt32(blob, start + 4),
      scalarCount: readUInt32(blob, start + 8),
      colorCount: readUInt32(blob, start + 12))
    guard byteCount(for: header) == Swift.Int(length) else { return nil }

    var cursor = start + headerByteCount
    var verbs: [PaintPathVerb] = []
    verbs.reserveCapacity(Swift.Int(header.verbCount))
    for i in 0..<Swift.Int(header.verbCount) {
      guard let verb = PaintPathVerb(rawValue: blob[cursor + i]) else { return nil }
      verbs.append(verb)
    }
    cursor += alignUp4(Swift.Int(header.verbCount))

    var points: [Swift.Float] = []
    points.reserveCapacity(Swift.Int(header.pointCount))
    for i in 0..<Swift.Int(header.pointCount) {
      points.append(readFloat(blob, cursor + i * 4))
    }
    cursor += Swift.Int(header.pointCount) * 4

    // The verbs must exactly consume the point region. A mismatch means the
    // producer and this format disagree.
    guard verbs.reduce(0, { $0 + $1.floatCount }) == points.count else { return nil }

    var scalars: [Swift.Float] = []
    scalars.reserveCapacity(Swift.Int(header.scalarCount))
    for i in 0..<Swift.Int(header.scalarCount) {
      scalars.append(readFloat(blob, cursor + i * 4))
    }
    cursor += Swift.Int(header.scalarCount) * 4

    var colors: [Color] = []
    colors.reserveCapacity(Swift.Int(header.colorCount))
    for i in 0..<Swift.Int(header.colorCount) {
      let base = cursor + i * 16
      colors.append(Color(
        r: readFloat(blob, base), g: readFloat(blob, base + 4),
        b: readFloat(blob, base + 8), a: readFloat(blob, base + 12)))
    }
    return Regions(verbs: verbs, points: points, scalars: scalars, colors: colors)
  }

  static func readUInt32(_ blob: [Swift.UInt8], _ index: Swift.Int) -> Swift.UInt32 {
    Swift.UInt32(blob[index])
      | (Swift.UInt32(blob[index + 1]) << 8)
      | (Swift.UInt32(blob[index + 2]) << 16)
      | (Swift.UInt32(blob[index + 3]) << 24)
  }

  static func readFloat(_ blob: [Swift.UInt8], _ index: Swift.Int) -> Swift.Float {
    Swift.Float(bitPattern: readUInt32(blob, index))
  }
}
