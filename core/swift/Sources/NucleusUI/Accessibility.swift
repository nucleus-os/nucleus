/// Stable identity in one semantic UI context.
///
/// The two-part representation avoids stealing bits from `ViewID` or
/// `WindowID` and leaves room for virtual elements whose identity is not a
/// renderable view.
public struct AccessibilityID: Hashable, Sendable, Comparable {
    public let context: UInt32
    public let ordinal: UInt64

    public init(context: UInt32, ordinal: UInt64) {
        precondition(context != 0, "accessibility context zero is reserved")
        precondition(ordinal != 0, "accessibility ordinal zero is reserved")
        self.context = context
        self.ordinal = ordinal
    }

    public static func < (
        lhs: AccessibilityID,
        rhs: AccessibilityID
    ) -> Bool {
        lhs.context == rhs.context
            ? lhs.ordinal < rhs.ordinal
            : lhs.context < rhs.context
    }

    /// A stable, D-Bus-object-path-safe representation.
    public var pathComponent: String {
        "\(String(context, radix: 16))_\(String(ordinal, radix: 16))"
    }
}

@MainActor
public protocol Accessible: AnyObject {
    var accessibilityID: AccessibilityID { get }
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
    case application
    case window
    case dialog
    case alert
    case group
    case button
    case toggleButton
    case checkBox
    case radioGroup
    case radioButton
    case switchControl
    case slider
    case rangeSlider
    case progressIndicator
    case separator
    case staticText
    case heading
    case textField
    case textArea
    case image
    case link
    case list
    case listItem
    case grid
    case gridCell
    case menu
    case menuItem
    case tabList
    case tab
    case comboBox
    case popover
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
    public static let secureText = AccessibilityTraits(rawValue: 1 << 5)
    public static let editable = AccessibilityTraits(rawValue: 1 << 6)
    public static let modal = AccessibilityTraits(rawValue: 1 << 7)
    public static let expanded = AccessibilityTraits(rawValue: 1 << 8)
    public static let checked = AccessibilityTraits(rawValue: 1 << 9)
    public static let liveRegion = AccessibilityTraits(rawValue: 1 << 10)
    public static let multiline = AccessibilityTraits(rawValue: 1 << 11)
    public static let readOnly = AccessibilityTraits(rawValue: 1 << 12)
}

public struct AccessibilityState: OptionSet, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let enabled = AccessibilityState(rawValue: 1 << 0)
    public static let focused = AccessibilityState(rawValue: 1 << 1)
    public static let focusable = AccessibilityState(rawValue: 1 << 2)
    public static let selected = AccessibilityState(rawValue: 1 << 3)
    public static let checked = AccessibilityState(rawValue: 1 << 4)
    public static let expanded = AccessibilityState(rawValue: 1 << 5)
    public static let editable = AccessibilityState(rawValue: 1 << 6)
    public static let secure = AccessibilityState(rawValue: 1 << 7)
    public static let modal = AccessibilityState(rawValue: 1 << 8)
    public static let visible = AccessibilityState(rawValue: 1 << 9)
    public static let active = AccessibilityState(rawValue: 1 << 10)
    public static let multiline = AccessibilityState(rawValue: 1 << 11)
}

public enum AccessibilityOrientation: String, Sendable, Equatable {
    case horizontal
    case vertical
}

public struct AccessibilityRangeValue: Sendable, Equatable {
    public var minimum: Double
    public var maximum: Double
    public var current: Double
    public var increment: Double?

    public init(
        minimum: Double,
        maximum: Double,
        current: Double,
        increment: Double? = nil
    ) {
        let lower = minimum.isFinite ? minimum : 0
        let upper = maximum.isFinite ? max(lower, maximum) : lower
        self.minimum = lower
        self.maximum = upper
        self.current = min(
            max(lower, current.isFinite ? current : lower),
            upper)
        self.increment = increment.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
    }
}

public struct AccessibilityTextSelection: Sendable, Equatable {
    public var utf16Range: Range<Int>

    public init(utf16Range: Range<Int>) {
        let lower = max(0, utf16Range.lowerBound)
        self.utf16Range = lower..<max(lower, utf16Range.upperBound)
    }
}

public enum AccessibilityRelationshipKind: String, Sendable, Hashable {
    case labelledBy
    case describedBy
    case controls
    case controlledBy
    case memberOf
    case flowsTo
}

public enum AccessibilityLiveRegion: String, Sendable, Equatable {
    case off
    case polite
    case assertive
}

public enum AccessibilityAction: String, Sendable, Hashable {
    case focus
    case press
    case increment
    case decrement
    case setValue
    case select
    case expand
    case collapse
    case dismiss
    case setText
    case setSelection
    case copy
    case cut
    case paste
    case selectAll
    case undo
    case redo
    case startDrag
    case performDrop
    case cancelDrag
}

public struct AccessibilityActionRequest: Sendable, Equatable {
    public var target: AccessibilityID
    public var action: AccessibilityAction
    public var text: String?
    public var selection: AccessibilityTextSelection?
    public var value: Double?

    public init(
        target: AccessibilityID,
        action: AccessibilityAction,
        text: String? = nil,
        selection: AccessibilityTextSelection? = nil,
        value: Double? = nil
    ) {
        self.target = target
        self.action = action
        self.text = text
        self.selection = selection
        self.value = value.flatMap { $0.isFinite ? $0 : nil }
    }
}

public struct AccessibilityProperties: Sendable, Equatable {
    public var isElement: Bool
    public var label: String?
    public var hint: String?
    public var description: String?
    public var value: String?
    public var role: AccessibilityRole?
    public var traits: AccessibilityTraits
    public var orientation: AccessibilityOrientation?
    public var rangeValue: AccessibilityRangeValue?
    public var textSelection: AccessibilityTextSelection?
    public var relationships:
        [AccessibilityRelationshipKind: [AccessibilityID]]
    public var liveRegion: AccessibilityLiveRegion

    public init(
        isElement: Bool = false,
        label: String? = nil,
        hint: String? = nil,
        description: String? = nil,
        value: String? = nil,
        role: AccessibilityRole? = nil,
        traits: AccessibilityTraits = [],
        orientation: AccessibilityOrientation? = nil,
        rangeValue: AccessibilityRangeValue? = nil,
        textSelection: AccessibilityTextSelection? = nil,
        relationships:
            [AccessibilityRelationshipKind: [AccessibilityID]] = [:],
        liveRegion: AccessibilityLiveRegion = .off
    ) {
        self.isElement = isElement
        self.label = label
        self.hint = hint
        self.description = description
        self.value = value
        self.role = role
        self.traits = traits
        self.orientation = orientation
        self.rangeValue = rangeValue
        self.textSelection = textSelection
        self.relationships = relationships
        self.liveRegion = liveRegion
    }
}

/// A semantic child that remains discoverable without a materialized `View`.
///
/// Its frame is in the owning view's coordinate system. The accessibility tree
/// converts that frame through the same view/window/scene pipeline as visual
/// content.
@MainActor
public struct AccessibilityVirtualElement {
    public var id: AccessibilityID
    public var properties: AccessibilityProperties
    public var frame: Rect
    public var actions: Set<AccessibilityAction>
    public var children: [AccessibilityVirtualElement]
    package var actionHandler:
        (@MainActor (AccessibilityActionRequest) -> Bool)?

    public init(
        id: AccessibilityID,
        properties: AccessibilityProperties,
        frame: Rect,
        actions: Set<AccessibilityAction> = [],
        children: [AccessibilityVirtualElement] = [],
        performAction:
            (@MainActor (AccessibilityActionRequest) -> Bool)? = nil
    ) {
        self.id = id
        self.properties = properties
        self.frame = frame
        self.actions = actions
        self.children = children
        self.actionHandler = performAction
    }
}

public struct AccessibilityNodeSnapshot: Sendable, Equatable {
    public var id: AccessibilityID
    public var parentID: AccessibilityID?
    public var childIDs: [AccessibilityID]
    public var windowID: WindowID
    public var role: AccessibilityRole
    public var label: String?
    public var description: String?
    public var value: String?
    public var state: AccessibilityState
    public var actions: Set<AccessibilityAction>
    public var orientation: AccessibilityOrientation?
    public var rangeValue: AccessibilityRangeValue?
    public var textSelection: AccessibilityTextSelection?
    public var relationships:
        [AccessibilityRelationshipKind: [AccessibilityID]]
    public var frameInScene: Rect
    public var liveRegion: AccessibilityLiveRegion

    public init(
        id: AccessibilityID,
        parentID: AccessibilityID?,
        childIDs: [AccessibilityID],
        windowID: WindowID,
        role: AccessibilityRole,
        label: String?,
        description: String?,
        value: String?,
        state: AccessibilityState,
        actions: Set<AccessibilityAction>,
        orientation: AccessibilityOrientation?,
        rangeValue: AccessibilityRangeValue?,
        textSelection: AccessibilityTextSelection?,
        relationships:
            [AccessibilityRelationshipKind: [AccessibilityID]],
        frameInScene: Rect,
        liveRegion: AccessibilityLiveRegion
    ) {
        self.id = id
        self.parentID = parentID
        self.childIDs = childIDs
        self.windowID = windowID
        self.role = role
        self.label = label
        self.description = description
        self.value = value
        self.state = state
        self.actions = actions
        self.orientation = orientation
        self.rangeValue = rangeValue
        self.textSelection = textSelection
        self.relationships = relationships
        self.frameInScene = frameInScene
        self.liveRegion = liveRegion
    }
}

public enum AccessibilityNotificationKind: String, Sendable, Equatable {
    case focus
    case value
    case selection
    case structure
    case bounds
    case announcement
    case liveRegion
}

public struct AccessibilityNotification: Sendable, Equatable {
    public var kind: AccessibilityNotificationKind
    public var target: AccessibilityID?
    public var announcement: String?

    public init(
        kind: AccessibilityNotificationKind,
        target: AccessibilityID? = nil,
        announcement: String? = nil
    ) {
        self.kind = kind
        self.target = target
        self.announcement = announcement
    }
}

public struct AccessibilityTreeSnapshot: Sendable, Equatable {
    public var revision: UInt64
    public var rootIDs: [AccessibilityID]
    public var nodes: [AccessibilityID: AccessibilityNodeSnapshot]

    public init(
        revision: UInt64 = 0,
        rootIDs: [AccessibilityID] = [],
        nodes: [AccessibilityID: AccessibilityNodeSnapshot] = [:]
    ) {
        self.revision = revision
        self.rootIDs = rootIDs
        self.nodes = nodes
    }
}

public struct AccessibilityTreeUpdate: Sendable, Equatable {
    public var revision: UInt64
    public var rootIDs: [AccessibilityID]
    public var inserted: [AccessibilityNodeSnapshot]
    public var updated: [AccessibilityNodeSnapshot]
    public var removed: [AccessibilityID]
    public var notifications: [AccessibilityNotification]

    public init(
        revision: UInt64,
        rootIDs: [AccessibilityID],
        inserted: [AccessibilityNodeSnapshot],
        updated: [AccessibilityNodeSnapshot],
        removed: [AccessibilityID],
        notifications: [AccessibilityNotification]
    ) {
        self.revision = revision
        self.rootIDs = rootIDs
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
        self.notifications = notifications
    }

    public var isEmpty: Bool {
        inserted.isEmpty
            && updated.isEmpty
            && removed.isEmpty
            && notifications.isEmpty
    }
}
