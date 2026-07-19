import NucleusTypes

public struct ImageHandle: Hashable, Sendable {
    package let rawValue: NucleusTypes.ImageHandle

    public init(id: UInt64) {
        self.rawValue = NucleusTypes.ImageHandle(id: id)
    }

    package init(rawValue: NucleusTypes.ImageHandle) {
        self.rawValue = rawValue
    }

    public var id: UInt64 {
        rawValue.id
    }

    public static func == (lhs: ImageHandle, rhs: ImageHandle) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// How an image fills a frame that is not its own shape.
///
/// The frame is authoritative — layout decides how big an image is, and the mode
/// decides what happens to the pixels inside that decision. This is the
/// reference's `FitMode` and it is the right split: a shell sizes an avatar or a
/// tray icon from its layout, never from what the file happens to contain.
public enum ImageContentMode: Sendable, Equatable {
    /// Fill the frame exactly, distorting if the aspect ratios differ.
    case stretch
    /// Fit entirely inside the frame, letterboxing the remainder.
    case contain
    /// Cover the frame entirely, cropping the overflow.
    case cover
}

@MainActor
public final class ImageView: View, ~Sendable {
    public var image: ImageHandle? {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    /// The image's own size, when known.
    ///
    /// Drives `intrinsicContentSize`, and is what `contain` and `cover` measure
    /// their aspect ratio against. It is not discovered from the file: decode
    /// happens in the renderer, so nothing on this side of the seam has seen the
    /// pixels. A caller that knows the size states it; one that does not gets
    /// `stretch` behaviour from the aspect-preserving modes, which is the only
    /// honest fallback.
    public var imageSize: Size {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    public var contentMode: ImageContentMode = .stretch {
        didSet { if contentMode != oldValue { setNeedsDisplay() } }
    }

    /// The registration backing `image`, when this view owns one.
    ///
    /// Assigning replaces `image` and drops the previous registration — which is
    /// the whole point of the resource owning its handle: releasing is forgetting.
    public var resource: ImageResource? {
        didSet {
            guard resource !== oldValue else { return }
            image = resource?.handle
        }
    }

    /// The file this view shows, decoded to fit the view.
    ///
    /// Registration is deferred until the view has a size, and repeats when the
    /// size it needs changes — the decode bounds are part of a registration's
    /// identity, so a view that grew is a different decode rather than an upscale
    /// of the old one.
    public var sourcePath: String? {
        didSet {
            guard sourcePath != oldValue else { return }
            resource = nil
            updateSourceRegistration()
        }
    }

    public init(image: ImageHandle? = nil, imageSize: Size = .zero) {
        self.image = image
        self.imageSize = imageSize
        super.init()
        accessibilityRole = .image
    }

    public convenience init(path: String, imageSize: Size = .zero) {
        self.init(image: nil, imageSize: imageSize)
        self.sourcePath = path
        updateSourceRegistration()
    }

    public override var intrinsicContentSize: Size {
        image == nil ? .zero : imageSize
    }

    public override func arrange(in rect: Rect) {
        super.arrange(in: rect)
        updateSourceRegistration()
    }

    /// Register (or re-register) the source at the size this view now needs.
    private func updateSourceRegistration() {
        guard let sourcePath else { return }
        let needed = bounds.size
        guard needed.width > 0, needed.height > 0 else { return }
        // Same file at the same bounds is the same decode; the store would dedupe
        // to the same handle anyway, so do not churn the registration.
        if let resource, resource.path == sourcePath, resource.decodeSize == needed {
            return
        }
        resource = ImageResource(
            path: sourcePath,
            decodeSize: needed,
            resourceHostHandle: backingLayer.context.commitSink.resourceHostHandle)
    }

    /// Where the image lands inside `bounds`, given the mode.
    ///
    /// Aspect-preserving modes need the image's own size; without it there is no
    /// ratio to preserve and the frame is the only information available, so they
    /// fill it.
    func destinationRect() -> Rect {
        let frame = bounds.size
        guard contentMode != .stretch,
              imageSize.width > 0, imageSize.height > 0,
              frame.width > 0, frame.height > 0
        else {
            return Rect(origin: .zero, size: frame)
        }

        let widthRatio = frame.width / imageSize.width
        let heightRatio = frame.height / imageSize.height
        let scale = contentMode == .contain
            ? min(widthRatio, heightRatio)
            : max(widthRatio, heightRatio)

        let size = Size(width: imageSize.width * scale, height: imageSize.height * scale)
        // Centred: an off-centre letterbox or crop reads as a layout bug.
        return Rect(
            origin: Point(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2),
            size: size)
    }

    public override func draw(in context: GraphicsContext) {
        guard let image else { return }
        let destination = destinationRect()
        guard destination.size.width > 0, destination.size.height > 0 else { return }

        if contentMode == .cover {
            // Cover overflows the frame by construction, so the frame must clip.
            context.saveGState()
            context.clip(to: Rect(origin: .zero, size: bounds.size))
            context.draw(image, in: destination, cornerRadius: cornerRadius)
            context.restoreGState()
            return
        }
        context.draw(image, in: destination, cornerRadius: cornerRadius)
    }
}
