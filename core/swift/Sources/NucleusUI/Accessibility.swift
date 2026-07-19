@MainActor
public protocol Accessible: AnyObject {
    var isAccessibilityElement: Bool { get set }
    var accessibilityLabel: String? { get set }
    var accessibilityHint: String? { get set }
    var accessibilityValue: String? { get set }
    var accessibilityRole: AccessibilityRole? { get set }
    var accessibilityTraits: AccessibilityTraits { get set }
    var accessibilityChildren: [any Accessible]? { get set }
    var accessibilityProperties: AccessibilityProperties { get set }
}

public enum AccessibilityRole: String, Sendable, Equatable {
    case button
    case image
    case link
    case progressIndicator
    case staticText
    case textField
    case window
}

public struct AccessibilityTraits: OptionSet, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let button = AccessibilityTraits(rawValue: 1 << 0)
    public static let image = AccessibilityTraits(rawValue: 1 << 1)
    public static let selected = AccessibilityTraits(rawValue: 1 << 2)
    public static let disabled = AccessibilityTraits(rawValue: 1 << 3)
    public static let updatesFrequently = AccessibilityTraits(rawValue: 1 << 4)
}

public struct AccessibilityProperties: Sendable, Equatable {
    public var isElement: Bool
    public var label: String?
    public var hint: String?
    public var value: String?
    public var role: AccessibilityRole?
    public var traits: AccessibilityTraits

    public init(
        isElement: Bool = false,
        label: String? = nil,
        hint: String? = nil,
        value: String? = nil,
        role: AccessibilityRole? = nil,
        traits: AccessibilityTraits = []
    ) {
        self.isElement = isElement
        self.label = label
        self.hint = hint
        self.value = value
        self.role = role
        self.traits = traits
    }
}
