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

@MainActor
public final class ImageView: View, ~Sendable {
    public var image: ImageHandle? {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
    public var imageSize: Size {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
    public init(image: ImageHandle? = nil, imageSize: Size = .zero) {
        self.image = image
        self.imageSize = imageSize
        super.init()
    }

    public override var intrinsicContentSize: Size {
        intrinsicContentSizeNeedsUpdate = false
        return image == nil ? .zero : imageSize
    }

    package override func displayCommands(in dirtyRect: Rect) -> [ViewLayerContentCommand] {
        guard let image else {
            return []
        }
        return [
            LayerContentBuilder.image(image, bounds: bounds, fallbackSize: imageSize, cornerRadius: Float(cornerRadius)),
        ]
    }
}
