// Pixel-layout vocabulary for the image seam.
//
// It lives beside the protocols rather than in the render tier because both
// sides of the seam speak it: a caller describes the layout it has, and the
// renderer normalizes it. Putting it in the render tier would force every
// producer to depend on the renderer to name a byte order.

/// The channel orders a raw pixel buffer can arrive in.
///
/// Notifications carry pixels over D-Bus rather than a path, and the sender
/// chooses the layout — so this is not a menu of conveniences, it is the set
/// that actually shows up.
public enum PixelChannelOrder: UInt8, Sendable, Equatable, CaseIterable {
    case rgba
    case bgra
    case argb
    case rgb
    case bgr

    /// Bytes per pixel in the *source* layout.
    public var sourceBytesPerPixel: Int {
        switch self {
        case .rgba, .bgra, .argb: 4
        case .rgb, .bgr: 3
        }
    }

    public var hasAlpha: Bool {
        switch self {
        case .rgba, .bgra, .argb: true
        case .rgb, .bgr: false
        }
    }
}
