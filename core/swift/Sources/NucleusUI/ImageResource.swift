import NucleusAppHostProtocols
import NucleusLayers

/// One registered image file, owning its registration for as long as it lives.
///
/// This is the producer the view tier lacked. Registration hands back a handle at
/// refcount one, so *something* must own that reference and drop it — an object
/// whose lifetime is the registration's is the cheapest way to make that
/// impossible to get wrong, and it lets a view release simply by forgetting.
///
/// Registration is by path and decode bounds; the renderer decodes lazily at
/// rasterization. Nothing here touches the GPU, so it works in a headless
/// bring-up where no recorder exists.
@MainActor
public final class ImageResource {
    public let handle: ImageHandle
    public let path: String

    /// The bounds the file was registered to decode within. Part of the
    /// registration's identity, not a hint: the store dedupes on path *and*
    /// bounds, so a different size is a different handle and a different decode.
    public let decodeSize: Size

    private let resourceHostHandle: UInt64

    /// Register `path`, or fail.
    ///
    /// Returns `nil` rather than throwing on a missing host, because "no host
    /// installed" is the headless-test and pre-bring-up case rather than a
    /// caller error, and a view that cannot show an image should draw nothing
    /// rather than take the process down.
    ///
    /// - Parameter decodeSize: the box to decode within. Zero on an axis means
    ///   unbounded there, which decodes at full size.
    public init?(path: String, decodeSize: Size = .zero, resourceHostHandle: UInt64) {
        guard !path.isEmpty, resourceHostHandle != 0 else { return nil }
        guard let registrar = currentHost()?.imageRegistrar else { return nil }

        let raw: UInt64
        do {
            raw = try registrar.register(
                path: path,
                maxWidth: ImageResource.pixelBound(decodeSize.width),
                maxHeight: ImageResource.pixelBound(decodeSize.height))
        } catch {
            return nil
        }
        guard raw != 0 else { return nil }

        self.handle = ImageHandle(id: raw)
        self.path = path
        self.decodeSize = decodeSize
        self.resourceHostHandle = resourceHostHandle
    }

    /// Register an image given by a path *or* a `data:` URI.
    ///
    /// Callers receive icon strings from applications and desktop entries and
    /// cannot know which they hold, so deciding here means no caller has to.
    public convenience init?(
        source: String, decodeSize: Size = .zero, resourceHostHandle: UInt64
    ) {
        if let uri = DataURI.parse(source) {
            self.init(
                encoded: uri.bytes, decodeSize: decodeSize,
                resourceHostHandle: resourceHostHandle)
        } else {
            self.init(
                path: source, decodeSize: decodeSize,
                resourceHostHandle: resourceHostHandle)
        }
    }

    /// Register encoded bytes already in memory.
    public init?(encoded bytes: [UInt8], decodeSize: Size = .zero, resourceHostHandle: UInt64) {
        guard !bytes.isEmpty, resourceHostHandle != 0 else { return nil }
        guard let registrar = currentHost()?.imageRegistrar else { return nil }

        let raw: UInt64
        do {
            raw = try bytes.withUnsafeBufferPointer { pointer in
                try registrar.register(
                    encoded: Span(_unsafeElements: pointer),
                    maxWidth: ImageResource.pixelBound(decodeSize.width),
                    maxHeight: ImageResource.pixelBound(decodeSize.height))
            }
        } catch {
            return nil
        }
        guard raw != 0 else { return nil }

        self.handle = ImageHandle(id: raw)
        self.path = ""
        self.decodeSize = decodeSize
        self.resourceHostHandle = resourceHostHandle
    }

    /// Register decoded pixels, as notifications deliver them over D-Bus.
    ///
    /// Decode bounds do not apply: the sender already chose the size, and there
    /// is nothing left to decode.
    public init?(
        pixels: [UInt8], width: Int, height: Int, rowStride: Int? = nil,
        order: PixelChannelOrder, isPremultiplied: Bool = false,
        resourceHostHandle: UInt64
    ) {
        guard !pixels.isEmpty, width > 0, height > 0, resourceHostHandle != 0 else { return nil }
        guard let registrar = currentHost()?.imageRegistrar else { return nil }

        let stride = rowStride ?? (width * order.sourceBytesPerPixel)
        let raw: UInt64
        do {
            raw = try pixels.withUnsafeBufferPointer { pointer in
                try registrar.register(
                    pixels: Span(_unsafeElements: pointer),
                    width: UInt32(width), height: UInt32(height),
                    rowStride: UInt32(stride), channelOrder: order.rawValue,
                    isPremultiplied: isPremultiplied)
            }
        } catch {
            return nil
        }
        guard raw != 0 else { return nil }

        self.handle = ImageHandle(id: raw)
        self.path = ""
        self.decodeSize = Size(width: Double(width), height: Double(height))
        self.resourceHostHandle = resourceHostHandle
    }

    /// A non-integral or non-positive size is unbounded. Rounding up rather than
    /// down keeps a half-pixel layout from decoding one pixel short and
    /// upscaling to cover the gap.
    static func pixelBound(_ value: Double) -> UInt32 {
        guard value.isFinite, value > 0 else { return 0 }
        return UInt32(min(value.rounded(.up), Double(UInt32.max)))
    }

    deinit {
        // `currentLifecycleHost` is deliberately nonisolated — release runs from
        // deinits that are not on the main actor.
        currentLifecycleHost()?.imageLifecycle.release(
            resourceHostHandle: resourceHostHandle, handle: handle.id)
    }
}
