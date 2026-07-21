import NucleusLinuxDBus
import NucleusUI

extension AtSPIService {
    func handleAction(
        _ message: SDBusMessage,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        let actions = object.parameterlessActions
        switch member {
        case "GetName", "GetLocalizedName":
            guard let action = indexedAction(message, actions: actions) else {
                return invalidArguments(message)
            }
            return reply(message) { $0.string(actionName(action)) }
        case "GetDescription":
            guard let action = indexedAction(message, actions: actions) else {
                return invalidArguments(message)
            }
            return reply(message) {
                $0.string(actionDescription(action))
            }
        case "GetKeyBinding":
            guard indexedAction(message, actions: actions) != nil else {
                return invalidArguments(message)
            }
            return reply(message) { $0.string("") }
        case "GetActions":
            return reply(message) { writer in
                writer.actionDescriptions(actions.map {
                    (
                        name: actionName($0),
                        description: actionDescription($0),
                        keyBinding: ""
                    )
                })
            }
        case "DoAction":
            guard let action = indexedAction(message, actions: actions),
                  let id = object.id
            else { return invalidArguments(message) }
            let accepted = onAction?(.init(
                target: id,
                action: action)) ?? false
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.action,
                member: member)
        }
    }


    func handleComponent(
        _ message: SDBusMessage,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        switch member {
        case "Contains":
            guard let x = readInt32(message),
                  let y = readInt32(message),
                  readUInt32(message) != nil
            else { return invalidArguments(message) }
            return reply(message) {
                $0.boolean(object.frame.contains(Point(
                    x: Double(x),
                    y: Double(y))))
            }
        case "GetAccessibleAtPoint":
            guard let x = readInt32(message),
                  let y = readInt32(message),
                  readUInt32(message) != nil
            else { return invalidArguments(message) }
            let point = Point(x: Double(x), y: Double(y))
            let path = deepestObject(at: point, below: object)
                ?? AtSPIExportModel.nullPath
            return reply(message) {
                $0.objectReference(busName: uniqueName, path: path)
            }
        case "GetExtents":
            guard readUInt32(message) != nil else {
                return invalidArguments(message)
            }
            return reply(message) {
                $0.rect(object.frame)
            }
        case "GetPosition":
            guard readUInt32(message) != nil else {
                return invalidArguments(message)
            }
            return reply(message) {
                let first = $0.int32(atSPIWireInt32(object.frame.origin.x))
                guard first >= 0 else { return first }
                return $0.int32(atSPIWireInt32(object.frame.origin.y))
            }
        case "GetSize":
            return reply(message) {
                let first = $0.int32(atSPIWireInt32(object.frame.size.width))
                guard first >= 0 else { return first }
                return $0.int32(atSPIWireInt32(object.frame.size.height))
            }
        case "GetLayer":
            return reply(message) {
                $0.uint32(Self.isWindowRole(object.role) ? 7 : 3)
            }
        case "GetMDIZOrder":
            return reply(message) { $0.int16(0) }
        case "GrabFocus":
            guard let id = object.id else {
                return reply(message) { $0.boolean(false) }
            }
            let accepted = onAction?(.init(
                target: id,
                action: .focus)) ?? false
            return reply(message) { $0.boolean(accepted) }
        case "GetAlpha":
            return reply(message) { $0.double(1) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.component,
                member: member)
        }
    }

    func handleValue(
        _ message: SDBusMessage,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        guard object.range != nil else {
            return unknownMethod(
                message,
                interface: AtSPIInterface.value,
                member: member)
        }
        switch member {
        case "SetCurrentValue":
            guard let value = readDouble(message),
                  let id = object.id
            else { return invalidArguments(message) }
            let accepted = onAction?(.init(
                target: id,
                action: .setValue,
                value: value)) ?? false
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.value,
                member: member)
        }
    }


    func handleSelection(
        _ message: SDBusMessage,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        let selected = object.childPaths.filter {
            model.objects[$0].map(isSelected) == true
        }
        switch member {
        case "GetNSelectedChildren":
            return reply(message) {
                $0.int32(Int32(clamping: selected.count))
            }
        case "GetSelectedChild":
            guard let index = readInt32(message) else {
                return invalidArguments(message)
            }
            let path = selected.indices.contains(Int(index))
                ? selected[Int(index)]
                : AtSPIExportModel.nullPath
            return reply(message) {
                $0.objectReference(
                    busName: path == AtSPIExportModel.nullPath
                        ? "" : uniqueName,
                    path: path)
            }
        case "SelectChild":
            guard let index = readInt32(message),
                  object.childPaths.indices.contains(Int(index)),
                  let child = model.objects[object.childPaths[Int(index)]],
                  let id = child.id
            else { return invalidArguments(message) }
            let accepted = onAction?(.init(
                target: id,
                action: .select)) ?? false
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.selection,
                member: member)
        }
    }


    func indexedAction(
        _ message: SDBusMessage,
        actions: [AccessibilityAction]
    ) -> AccessibilityAction? {
        guard let index = readInt32(message),
              index >= 0,
              actions.indices.contains(Int(index))
        else { return nil }
        return actions[Int(index)]
    }

    func actionName(_ action: AccessibilityAction) -> String {
        switch action {
        case .press: "click"
        case .select: "select"
        case .focus: "focus"
        case .increment: "increment"
        case .decrement: "decrement"
        case .expand: "expand"
        case .collapse: "collapse"
        case .dismiss: "dismiss"
        case .copy: "copy"
        case .cut: "cut"
        case .paste: "paste"
        case .selectAll: "select-all"
        case .undo: "undo"
        case .redo: "redo"
        case .startDrag: "start-drag"
        case .performDrop: "drop"
        case .cancelDrag: "cancel-drag"
        case .setValue, .setText, .setSelection: ""
        }
    }

    func actionDescription(_ action: AccessibilityAction) -> String {
        switch action {
        case .press: "Activates the control"
        case .select: "Selects the item"
        case .focus: "Moves keyboard focus to the control"
        case .increment: "Increases the value"
        case .decrement: "Decreases the value"
        case .expand: "Expands the control"
        case .collapse: "Collapses the control"
        case .dismiss: "Dismisses the control"
        case .copy: "Copies the selected text"
        case .cut: "Cuts the selected text"
        case .paste: "Pastes text"
        case .selectAll: "Selects all text"
        case .undo: "Undoes the previous edit"
        case .redo: "Redoes the previous edit"
        case .startDrag: "Starts dragging this item"
        case .performDrop: "Drops the active item here"
        case .cancelDrag: "Cancels the active drag"
        case .setValue, .setText, .setSelection: ""
        }
    }

    func isSelected(_ object: AtSPIExportedObject) -> Bool {
        let state = 23
        return object.states.indices.contains(state / 32)
            && object.states[state / 32] & (UInt32(1) << UInt32(state % 32)) != 0
    }

    func deepestObject(
        at point: Point,
        below root: AtSPIExportedObject
    ) -> String? {
        func descend(_ object: AtSPIExportedObject) -> String? {
            for path in object.childPaths.reversed() {
                guard let child = model.objects[path],
                      child.frame.contains(point)
                else { continue }
                return descend(child) ?? path
            }
            return nil
        }
        return descend(root)
    }


    static func isWindowRole(_ role: UInt32) -> Bool {
        role == 2 || role == 16 || role == 41 || role == 69
    }
}
