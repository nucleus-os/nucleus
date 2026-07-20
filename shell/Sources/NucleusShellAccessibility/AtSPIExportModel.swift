import NucleusUI

enum AtSPIInterface {
    static let accessible = "org.a11y.atspi.Accessible"
    static let action = "org.a11y.atspi.Action"
    static let application = "org.a11y.atspi.Application"
    static let component = "org.a11y.atspi.Component"
    static let editableText = "org.a11y.atspi.EditableText"
    static let selection = "org.a11y.atspi.Selection"
    static let text = "org.a11y.atspi.Text"
    static let value = "org.a11y.atspi.Value"
}

struct AtSPIExportedObject: Sendable, Equatable {
    var id: AccessibilityID?
    var path: String
    var parentPath: String?
    var childPaths: [String]
    var role: UInt32
    var roleName: String
    var name: String
    var description: String
    var valueText: String
    var states: [UInt32]
    var interfaces: [String]
    var actions: [AccessibilityAction]
    var frame: Rect
    var range: AccessibilityRangeValue?
    var textSelection: AccessibilityTextSelection?
    var relationships: [UInt32: [String]]
    var isSecure: Bool

    var text: String {
        guard !isSecure else { return "" }
        return valueText.isEmpty ? name : valueText
    }

    var parameterlessActions: [AccessibilityAction] {
        actions.filter {
            $0 != .setValue && $0 != .setText && $0 != .setSelection
        }
    }
}

enum AtSPIEventKind: Sendable, Equatable {
    case windowCreated
    case windowDestroyed
    case focus
    case valueChanged
    case selectionChanged
    case childrenAdded
    case childrenRemoved
    case boundsChanged
    case announcement
    case liveRegion
}

struct AtSPIEvent: Sendable, Equatable {
    var kind: AtSPIEventKind
    var sourcePath: String
    var relatedPath: String?
    var detail: String
    var text: String?

    init(
        kind: AtSPIEventKind,
        sourcePath: String,
        relatedPath: String? = nil,
        detail: String = "",
        text: String? = nil
    ) {
        self.kind = kind
        self.sourcePath = sourcePath
        self.relatedPath = relatedPath
        self.detail = detail
        self.text = text
    }
}

struct AtSPIExportUpdate: Sendable, Equatable {
    var objects: [String: AtSPIExportedObject]
    var addedPaths: [String]
    var removedPaths: [String]
    var events: [AtSPIEvent]
}

struct AtSPIExportModel: Sendable {
    static let rootPath = "/org/a11y/atspi/accessible/root"
    static let nullPath = "/org/a11y/atspi/null"

    private(set) var objects: [String: AtSPIExportedObject] = [:]
    private(set) var idToPath: [AccessibilityID: String] = [:]
    var applicationName: String

    init(applicationName: String) {
        self.applicationName = applicationName
    }

    mutating func apply(
        snapshot: AccessibilityTreeSnapshot,
        update: AccessibilityTreeUpdate
    ) -> AtSPIExportUpdate {
        let oldObjects = objects
        let oldPaths = Set(oldObjects.keys)
        var next: [String: AtSPIExportedObject] = [:]
        var nextIDToPath: [AccessibilityID: String] = [:]

        for node in snapshot.nodes.values {
            let path = Self.path(for: node.id)
            nextIDToPath[node.id] = path
        }
        let rootChildren = snapshot.rootIDs.compactMap {
            nextIDToPath[$0]
        }
        next[Self.rootPath] = applicationObject(children: rootChildren)
        for node in snapshot.nodes.values {
            let path = nextIDToPath[node.id]!
            next[path] = object(
                for: node,
                path: path,
                idToPath: nextIDToPath)
        }

        let nextPaths = Set(next.keys)
        let added = nextPaths.subtracting(oldPaths).sorted()
        let removed = oldPaths.subtracting(nextPaths).sorted()
        var events: [AtSPIEvent] = []

        for path in added where path != Self.rootPath {
            guard let object = next[path] else { continue }
            if Self.isWindowRole(object.role) {
                events.append(.init(
                    kind: .windowCreated,
                    sourcePath: path))
            }
            events.append(.init(
                kind: .childrenAdded,
                sourcePath: object.parentPath ?? Self.rootPath,
                relatedPath: path,
                detail: "add"))
        }
        for path in removed where path != Self.rootPath {
            guard let object = oldObjects[path] else { continue }
            events.append(.init(
                kind: .childrenRemoved,
                sourcePath: object.parentPath ?? Self.rootPath,
                relatedPath: path,
                detail: "remove"))
            if Self.isWindowRole(object.role) {
                events.append(.init(
                    kind: .windowDestroyed,
                    sourcePath: path))
            }
        }
        for notification in update.notifications {
            let currentPath = notification.target.flatMap {
                nextIDToPath[$0]
            }
            let oldPath = notification.target.flatMap {
                idToPath[$0]
            }
            guard let path = currentPath ?? oldPath else { continue }
            switch notification.kind {
            case .focus:
                events.append(.init(kind: .focus, sourcePath: path))
            case .value:
                events.append(.init(
                    kind: .valueChanged,
                    sourcePath: path,
                    detail: "accessible-value",
                    text: next[path]?.valueText))
            case .selection:
                events.append(.init(
                    kind: .selectionChanged,
                    sourcePath: path))
            case .structure:
                // Add/remove events above carry the concrete child reference.
                break
            case .bounds:
                events.append(.init(
                    kind: .boundsChanged,
                    sourcePath: path))
            case .announcement:
                events.append(.init(
                    kind: .announcement,
                    sourcePath: path,
                    text: notification.announcement))
            case .liveRegion:
                events.append(.init(
                    kind: .liveRegion,
                    sourcePath: path,
                    text: notification.announcement))
            }
        }

        objects = next
        idToPath = nextIDToPath
        return AtSPIExportUpdate(
            objects: next,
            addedPaths: added,
            removedPaths: removed,
            events: deduplicate(events))
    }

    func object(for id: AccessibilityID) -> AtSPIExportedObject? {
        idToPath[id].flatMap { objects[$0] }
    }

    static func path(for id: AccessibilityID) -> String {
        "/org/a11y/atspi/accessible/\(id.pathComponent)"
    }

    private func applicationObject(
        children: [String]
    ) -> AtSPIExportedObject {
        AtSPIExportedObject(
            id: nil,
            path: Self.rootPath,
            parentPath: nil,
            childPaths: children,
            role: 75,
            roleName: "application",
            name: applicationName,
            description: "",
            valueText: "",
            states: stateWords([1, 8, 24, 25, 30]),
            interfaces: [
                AtSPIInterface.accessible,
                AtSPIInterface.application,
                AtSPIInterface.component,
            ],
            actions: [],
            frame: .zero,
            range: nil,
            textSelection: nil,
            relationships: [:],
            isSecure: false)
    }

    private func object(
        for node: AccessibilityNodeSnapshot,
        path: String,
        idToPath: [AccessibilityID: String]
    ) -> AtSPIExportedObject {
        let role = atspiRole(node.role, secure: node.state.contains(.secure))
        let actions = node.actions.sorted {
            actionOrder($0) < actionOrder($1)
        }
        var interfaces = [
            AtSPIInterface.accessible,
            AtSPIInterface.component,
        ]
        if !actions.filter({
            $0 != .setValue && $0 != .setText && $0 != .setSelection
        }).isEmpty {
            interfaces.append(AtSPIInterface.action)
        }
        if node.rangeValue != nil {
            interfaces.append(AtSPIInterface.value)
        }
        if isTextRole(node.role), !node.state.contains(.secure) {
            interfaces.append(AtSPIInterface.text)
            if node.state.contains(.editable) {
                interfaces.append(AtSPIInterface.editableText)
            }
        }
        if isSelectionContainer(node.role) {
            interfaces.append(AtSPIInterface.selection)
        }
        return AtSPIExportedObject(
            id: node.id,
            path: path,
            parentPath: node.parentID.flatMap { idToPath[$0] }
                ?? Self.rootPath,
            childPaths: node.childIDs.compactMap { idToPath[$0] },
            role: role,
            roleName: roleName(node.role, secure: node.state.contains(.secure)),
            name: node.label ?? "",
            description: node.description ?? "",
            valueText: node.value ?? "",
            states: stateWords(atspiStates(node)),
            interfaces: interfaces,
            actions: actions,
            frame: node.frameInScene,
            range: node.rangeValue,
            textSelection: node.textSelection,
            relationships: Dictionary(
                uniqueKeysWithValues: node.relationships.map {
                    (relationshipCode($0.key),
                     $0.value.compactMap { idToPath[$0] })
                }),
            isSecure: node.state.contains(.secure))
    }

    private func atspiStates(
        _ node: AccessibilityNodeSnapshot
    ) -> [Int] {
        var values: [Int] = []
        let state = node.state
        if state.contains(.active) { values.append(1) }
        if state.contains(.checked) { values.append(4) }
        if state.contains(.editable) { values.append(7) }
        if state.contains(.enabled) { values += [8, 24] }
        if state.contains(.expanded) { values.append(10) }
        if state.contains(.focusable) { values.append(11) }
        if state.contains(.focused) { values.append(12) }
        if state.contains(.modal) { values.append(16) }
        if state.contains(.multiline) {
            values.append(17)
        } else if isTextRole(node.role) {
            values.append(26)
        }
        if node.orientation == .horizontal { values.append(14) }
        if node.orientation == .vertical { values.append(29) }
        if isSelectableRole(node.role) { values.append(22) }
        if state.contains(.selected) { values.append(23) }
        if state.contains(.visible) { values += [25, 30] }
        if isTextRole(node.role), !state.contains(.secure) {
            values.append(38)
        }
        if node.role == .checkBox
            || node.role == .radioButton
            || node.role == .switchControl
            || node.role == .toggleButton
        {
            values.append(41)
        }
        return values
    }

    private func stateWords(_ states: [Int]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: 2)
        for state in states where state >= 0 && state < 64 {
            result[state / 32] |= UInt32(1) << UInt32(state % 32)
        }
        return result
    }

    private func atspiRole(
        _ role: AccessibilityRole,
        secure: Bool
    ) -> UInt32 {
        if secure { return 40 }
        return switch role {
        case .application: 75
        case .window: 69
        case .dialog: 16
        case .alert: 2
        case .group, .radioGroup: 98
        case .button: 43
        case .toggleButton: 62
        case .checkBox: 7
        case .radioButton: 44
        case .switchControl: 130
        case .slider, .rangeSlider: 51
        case .progressIndicator: 42
        case .separator: 50
        case .staticText: 116
        case .heading: 83
        case .textField: 79
        case .textArea: 61
        case .image: 27
        case .link: 88
        case .list: 31
        case .listItem: 32
        case .grid: 55
        case .gridCell: 56
        case .menu: 33
        case .menuItem: 35
        case .tabList: 38
        case .tab: 37
        case .comboBox: 11
        case .popover: 41
        }
    }

    private func roleName(
        _ role: AccessibilityRole,
        secure: Bool
    ) -> String {
        secure ? "password text" : role.rawValue
    }

    private func isTextRole(_ role: AccessibilityRole) -> Bool {
        role == .textField || role == .textArea || role == .staticText
            || role == .heading
    }

    private func isSelectionContainer(_ role: AccessibilityRole) -> Bool {
        role == .list || role == .grid || role == .menu
            || role == .tabList || role == .radioGroup
    }

    private func isSelectableRole(_ role: AccessibilityRole) -> Bool {
        role == .listItem || role == .gridCell || role == .menuItem
            || role == .tab || role == .radioButton
    }

    private static func isWindowRole(_ role: UInt32) -> Bool {
        role == 2 || role == 16 || role == 41 || role == 69
    }

    private func actionOrder(_ action: AccessibilityAction) -> Int {
        switch action {
        case .press: 0
        case .select: 1
        case .focus: 2
        case .increment: 3
        case .decrement: 4
        case .setValue: 5
        case .expand: 6
        case .collapse: 7
        case .dismiss: 8
        case .setText: 9
        case .setSelection: 10
        case .copy: 11
        case .cut: 12
        case .paste: 13
        case .selectAll: 14
        case .undo: 15
        case .redo: 16
        }
    }

    private func relationshipCode(
        _ relationship: AccessibilityRelationshipKind
    ) -> UInt32 {
        switch relationship {
        case .labelledBy: 2
        case .describedBy: 18
        case .controls: 3
        case .controlledBy: 4
        case .memberOf: 5
        case .flowsTo: 10
        }
    }

    private func deduplicate(_ events: [AtSPIEvent]) -> [AtSPIEvent] {
        var seen: Set<EventKey> = []
        return events.filter { seen.insert(EventKey($0)).inserted }
    }

    private struct EventKey: Hashable {
        var kind: String
        var source: String
        var related: String?
        var detail: String
        var text: String?

        init(_ event: AtSPIEvent) {
            kind = String(describing: event.kind)
            source = event.sourcePath
            related = event.relatedPath
            detail = event.detail
            text = event.text
        }
    }
}
