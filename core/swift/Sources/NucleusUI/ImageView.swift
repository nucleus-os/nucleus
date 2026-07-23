package import NucleusTypes

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

private extension ImageRequestSource {
    var isIcon: Bool {
        if case .icon = self { return true }
        return false
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

public enum ImageLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(ImageRequestFailure)
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

    /// Recolour the image by its alpha, keeping shape and dropping colour.
    ///
    /// A spec rather than a colour, so a tinted icon follows a retheme like
    /// everything else. `nil` draws the image's own colours.
    public var tint: ColorSpec? {
        didSet { if tint != oldValue { setNeedsDisplay() } }
    }

    /// `1` leaves colour alone, `0` is fully grey. Applied before any tint, so a
    /// full-colour app icon can be desaturated and recoloured rather than
    /// flattened to a silhouette.
    public var saturation: Double = 1 {
        didSet { if saturation != oldValue { setNeedsDisplay() } }
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

    /// Retained source request. Direct files/data and named platform icons use
    /// the same bounded, coalescing context pipeline.
    public var source: ImageRequestSource? {
        didSet {
            guard source != oldValue else { return }
            invalidateSourceRequest()
        }
    }

    /// Generation supplied by the host's icon-theme owner.
    public var iconThemeGeneration: UInt64 = 0 {
        didSet {
            guard iconThemeGeneration != oldValue else { return }
            if case .icon = source {
                invalidateSourceRequest()
            }
        }
    }

    /// Optional projection scale for a detached embedder. Ordinary retained
    /// scenes derive scale from their presenting window.
    public var requestBackingScaleFactor: BackingScaleFactor? {
        didSet {
            guard requestBackingScaleFactor != oldValue else { return }
            invalidateSourceRequest()
        }
    }

    /// Consumer policy while a request is pending or has failed.
    public var placeholderImage: ImageHandle? {
        didSet {
            if loadState == .loading { image = placeholderImage }
        }
    }
    public var failureImage: ImageHandle? {
        didSet {
            if case .failed = loadState { image = failureImage }
        }
    }

    public private(set) var loadState: ImageLoadState = .idle

    private struct RequestInputs: Equatable {
        var source: ImageRequestSource
        var size: Size
        var scale: BackingScaleFactor
        var appearance: Appearance
        var iconThemeGeneration: UInt64
    }

    private var activeRequestInputs: RequestInputs?
    private var requestToken: ImageRequestToken?
    private var requestGeneration: UInt64 = 0

    public init(image: ImageHandle? = nil, imageSize: Size = .zero) {
        self.image = image
        self.imageSize = imageSize
        super.init()
        isAccessibilityElement = true
        accessibilityRole = .image
        accessibilityTraits.insert(.image)
    }

    public convenience init(
        source: ImageRequestSource,
        imageSize: Size = .zero
    ) {
        self.init(image: nil, imageSize: imageSize)
        self.source = source
        updateSourceRequest()
    }

    public override var intrinsicContentSize: Size {
        image == nil ? .zero : imageSize
    }

    public override func arrange(in rect: Rect) {
        super.arrange(in: rect)
        updateSourceRequest()
    }

    public override func layout() {
        super.layout()
        updateSourceRequest()
    }

    public override func viewDidChangeEffectiveAppearance() {
        if case .icon = source {
            invalidateSourceRequest()
        }
        super.viewDidChangeEffectiveAppearance()
    }

    public override func viewDidChangeBackingScaleFactor() {
        invalidateSourceRequest()
        super.viewDidChangeBackingScaleFactor()
    }

    public override func retainedHierarchyWillDetach() {
        requestToken?.cancel()
        requestToken = nil
        activeRequestInputs = nil
        resource = nil
        loadState = source == nil ? .idle : .loading
        image = source == nil ? nil : placeholderImage
        super.retainedHierarchyWillDetach()
    }

    private var effectiveRequestScale: BackingScaleFactor {
        requestBackingScaleFactor
            ?? window?.surfaceAssociation?.transform.backingScaleFactor
            ?? .one
    }

    private func invalidateSourceRequest() {
        requestToken?.cancel()
        requestToken = nil
        activeRequestInputs = nil
        resource = nil
        guard source != nil else {
            loadState = .idle
            image = nil
            return
        }
        loadState = .loading
        image = placeholderImage
        updateSourceRequest()
    }

    /// Resolve and register at the exact point size/backing scale this consumer
    /// needs. The renderer performs the actual decode through its existing
    /// queue after publication.
    private func updateSourceRequest() {
        guard let source else { return }
        let needed = bounds.size
        guard needed.width > 0, needed.height > 0 else { return }
        let inputs = RequestInputs(
            source: source,
            size: needed,
            scale: effectiveRequestScale,
            appearance: source.isIcon ? effectiveAppearance : .dark,
            iconThemeGeneration:
                source.isIcon ? iconThemeGeneration : 0)
        guard inputs != activeRequestInputs else { return }

        requestToken?.cancel()
        resource = nil
        image = placeholderImage
        loadState = .loading
        activeRequestInputs = inputs
        requestGeneration &+= 1
        precondition(
            requestGeneration != 0,
            "image view request generation exhausted")
        let generation = requestGeneration
        let request = ImageRequest(
            id: ImageRequestID(rawValue: id.rawValue),
            source: source,
            targetSize: needed,
            backingScaleFactor: inputs.scale,
            appearance: inputs.appearance,
            iconThemeGeneration: inputs.iconThemeGeneration,
            cancellationGeneration: generation)
        requestToken = uiContext.imageRequests.request(request) {
            [weak self] result in
            guard let self,
                  result.requestID.rawValue == self.id.rawValue,
                  result.cancellationGeneration == self.requestGeneration,
                  self.activeRequestInputs == inputs
            else { return }
            switch result.outcome {
            case .success(let resource):
                self.resource = resource
                self.loadState = .loaded
            case .failure(let failure):
                self.resource = nil
                self.image = self.failureImage
                self.loadState = .failed(failure)
            }
        }
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

        let resolvedTint = tint.map { resolve($0) }
        if contentMode == .cover {
            // Cover overflows the frame by construction, so the frame must clip.
            context.saveGState()
            context.clip(to: Rect(origin: .zero, size: bounds.size))
            context.draw(
                image, in: destination, cornerRadius: cornerRadius,
                tint: resolvedTint, saturation: saturation)
            context.restoreGState()
            return
        }
        context.draw(
            image, in: destination, cornerRadius: cornerRadius,
            tint: resolvedTint, saturation: saturation)
    }
}
