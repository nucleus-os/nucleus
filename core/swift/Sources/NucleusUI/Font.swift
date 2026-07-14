public struct FontDescriptor: Sendable, Equatable {
    public var familyName: String?
    public var pointSize: Float
    public var weight: Font.Weight
    public var width: Font.Width
    public var slant: Font.Slant

    public init(
        familyName: String? = nil,
        pointSize: Float,
        weight: Font.Weight = .regular,
        width: Font.Width = .standard,
        slant: Font.Slant = .upright
    ) {
        self.familyName = familyName
        self.pointSize = max(1, pointSize)
        self.weight = weight
        self.width = width
        self.slant = slant
    }

    public var resolved: ResolvedFontDescriptor {
        TextSystem.shared.resolve(self)
    }
}

public struct ResolvedFontDescriptor: Sendable, Equatable {
    public var familyName: String
    public var postScriptName: String
    public var pointSize: Float
    public var weight: Font.Weight
    public var width: Font.Width
    public var slant: Font.Slant

    public init(
        familyName: String,
        postScriptName: String,
        pointSize: Float,
        weight: Font.Weight,
        width: Font.Width = .standard,
        slant: Font.Slant = .upright
    ) {
        self.familyName = familyName
        self.postScriptName = postScriptName
        self.pointSize = max(1, pointSize)
        self.weight = weight
        self.width = width
        self.slant = slant
    }
}

public struct Font: Sendable, Equatable {
    public enum Weight: Sendable, Equatable {
        case regular
        case medium
        case semibold
        case bold
    }

    public enum Width: Sendable, Equatable {
        case compressed
        case condensed
        case standard
        case expanded
    }

    public enum Slant: Sendable, Equatable {
        case upright
        case italic
        case oblique
    }

    public var descriptor: FontDescriptor

    public var pointSize: Float {
        get { descriptor.pointSize }
        set { descriptor.pointSize = max(1, newValue) }
    }

    public var weight: Weight {
        get { descriptor.weight }
        set { descriptor.weight = newValue }
    }

    public var width: Width {
        get { descriptor.width }
        set { descriptor.width = newValue }
    }

    public var slant: Slant {
        get { descriptor.slant }
        set { descriptor.slant = newValue }
    }

    public init(
        pointSize: Float,
        weight: Weight = .regular,
        width: Width = .standard,
        slant: Slant = .upright
    ) {
        self.descriptor = FontDescriptor(pointSize: pointSize, weight: weight, width: width, slant: slant)
    }

    public init(descriptor: FontDescriptor) {
        self.descriptor = descriptor
    }

    public static func systemFont(
        ofSize pointSize: Float,
        weight: Weight = .regular,
        width: Width = .standard,
        slant: Slant = .upright
    ) -> Font {
        Font(pointSize: pointSize, weight: weight, width: width, slant: slant)
    }

    public var metrics: FontMetrics {
        TextSystem.shared.metrics(for: descriptor)
    }

    public var resolvedDescriptor: ResolvedFontDescriptor {
        descriptor.resolved
    }
}

public struct FontMetrics: Sendable, Equatable {
    public var ascender: Float
    public var descender: Float
    public var leading: Float
    public var capHeight: Float
    public var xHeight: Float

    public init(
        ascender: Float,
        descender: Float,
        leading: Float,
        capHeight: Float,
        xHeight: Float
    ) {
        self.ascender = ascender
        self.descender = descender
        self.leading = leading
        self.capHeight = capHeight
        self.xHeight = xHeight
    }

    public var lineHeight: Float {
        (ascender + descender + leading).rounded(.up)
    }

    public var firstBaselineOffsetFromTop: Float {
        leading * 0.5 + ascender
    }

    public var lastBaselineOffsetFromBottom: Float {
        max(0, lineHeight - firstBaselineOffsetFromTop)
    }
}
