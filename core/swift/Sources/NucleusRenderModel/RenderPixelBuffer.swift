public import NucleusAppHostProtocols

/// A raw image as it arrives from a sender: pixels, a layout, and a stride.
///
/// Stride is separate from width because a sender is free to pad rows, and
/// assuming `width * bytesPerPixel` silently skews every row after the first
/// into a diagonal smear.
public struct RawPixelBuffer: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Bytes per row in `pixels`, which may exceed `width * bytesPerPixel`.
    public var rowStride: Int
    public var order: PixelChannelOrder
    /// Whether the source's colour channels are already multiplied by alpha.
    ///
    /// The D-Bus notification spec says they are not, and the GPU wants them to
    /// be, so this defaults to the wire's answer rather than the GPU's.
    public var isPremultiplied: Bool
    public var pixels: [UInt8]

    public init(
        width: Int, height: Int, rowStride: Int? = nil,
        order: PixelChannelOrder, isPremultiplied: Bool = false, pixels: [UInt8]
    ) {
        self.width = width
        self.height = height
        if let rowStride {
            self.rowStride = rowStride
        } else {
            let packed = width.multipliedReportingOverflow(
                by: order.sourceBytesPerPixel)
            // Zero is always rejected below. Preserve construction as a total
            // operation even for adversarial dimensions so validation, hashing,
            // and diagnostics can inspect malformed wire input without trapping.
            self.rowStride = packed.overflow ? 0 : packed.partialValue
        }
        self.order = order
        self.isPremultiplied = isPremultiplied
        self.pixels = pixels
    }

    /// Whether the buffer holds enough bytes for the geometry it claims.
    ///
    /// The last row needs only its pixels, not a full stride — senders routinely
    /// omit the final padding, and rejecting those would reject valid buffers.
    public var isWellFormed: Bool {
        guard width > 0, height > 0 else { return false }
        let minimum = width.multipliedReportingOverflow(
            by: order.sourceBytesPerPixel)
        guard !minimum.overflow else { return false }
        let minimumStride = minimum.partialValue
        guard rowStride >= minimumStride else { return false }
        let precedingRows = (height - 1).multipliedReportingOverflow(
            by: rowStride)
        guard !precedingRows.overflow else { return false }
        let required = precedingRows.partialValue.addingReportingOverflow(
            minimumStride)
        return !required.overflow && pixels.count >= required.partialValue
    }

    /// Convert to tightly-packed premultiplied RGBA8888, which is what the
    /// texture upload path takes. Returns `nil` if the buffer does not describe
    /// itself consistently.
    public func normalizedRGBA() -> [UInt8]? {
        guard isWellFormed else { return nil }

        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard !pixelCount.overflow else { return nil }
        let outputCount = pixelCount.partialValue.multipliedReportingOverflow(
            by: 4)
        guard !outputCount.overflow else { return nil }

        let sourceBytesPerPixel = order.sourceBytesPerPixel
        var out = [UInt8](repeating: 0, count: outputCount.partialValue)

        for y in 0..<height {
            let rowStart = y * rowStride
            for x in 0..<width {
                let i = rowStart + x * sourceBytesPerPixel
                let r: UInt8, g: UInt8, b: UInt8, a: UInt8
                switch order {
                case .rgba:
                    r = pixels[i]; g = pixels[i + 1]; b = pixels[i + 2]; a = pixels[i + 3]
                case .bgra:
                    b = pixels[i]; g = pixels[i + 1]; r = pixels[i + 2]; a = pixels[i + 3]
                case .argb:
                    a = pixels[i]; r = pixels[i + 1]; g = pixels[i + 2]; b = pixels[i + 3]
                case .rgb:
                    r = pixels[i]; g = pixels[i + 1]; b = pixels[i + 2]; a = 255
                case .bgr:
                    b = pixels[i]; g = pixels[i + 1]; r = pixels[i + 2]; a = 255
                }

                let o = (y * width + x) * 4
                if isPremultiplied || a == 255 {
                    out[o] = r; out[o + 1] = g; out[o + 2] = b
                } else {
                    out[o] = RawPixelBuffer.premultiply(r, a)
                    out[o + 1] = RawPixelBuffer.premultiply(g, a)
                    out[o + 2] = RawPixelBuffer.premultiply(b, a)
                }
                out[o + 3] = a
            }
        }
        return out
    }

    /// Multiply a channel by alpha with rounding.
    ///
    /// `+ 127` rather than truncation: truncating loses roughly half a level on
    /// every channel of every pixel, which reads as a uniform darkening across
    /// any semi-transparent image.
    static func premultiply(_ channel: UInt8, _ alpha: UInt8) -> UInt8 {
        UInt8((Int(channel) * Int(alpha) + 127) / 255)
    }

    /// A content hash, for deduplicating registrations of identical pixels.
    ///
    /// Raw buffers have no path to key on, and a notification that re-sends the
    /// same icon on every update would otherwise register a new decode each
    /// time. FNV-1a over the geometry and the bytes.
    public func contentHash() -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        for value in [width, height, rowStride] {
            let word = UInt64(truncatingIfNeeded: value)
            for shift in stride(from: 0, to: UInt64.bitWidth, by: UInt8.bitWidth) {
                mix(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        mix(order.rawValue)
        mix(isPremultiplied ? 1 : 0)
        for byte in pixels { mix(byte) }
        return hash
    }
}
