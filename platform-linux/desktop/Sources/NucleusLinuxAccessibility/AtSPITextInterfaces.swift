import NucleusLinuxDBus
import NucleusUI

extension AtSPIService {
    func handleText(
        _ message: SDBusMessage,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        guard !object.isSecure else {
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.AccessDenied",
                text: "Secure text is not exported")
        }
        switch member {
        case "GetText":
            guard let start = readInt32(message),
                  let end = readInt32(message)
            else { return invalidArguments(message) }
            return reply(message) {
                $0.string(textSlice(
                    object.text,
                    start: Int(start),
                    end: Int(end)))
            }
        case "SetCaretOffset":
            guard let offset = readInt32(message),
                  let id = object.id
            else { return invalidArguments(message) }
            let utf16 = utf16Offset(
                in: object.text,
                characterOffset: Int(offset))
            let accepted = onAction?(.init(
                target: id,
                action: .setSelection,
                selection: .init(utf16Range: utf16..<utf16))) ?? false
            return reply(message) { $0.boolean(accepted) }
        case "GetNSelections":
            let count: Int32 = object.textSelection.map {
                $0.utf16Range.isEmpty ? 0 : 1
            } ?? 0
            return reply(message) { $0.int32(count) }
        case "GetSelection":
            guard readInt32(message) == 0,
                  let selection = object.textSelection
            else { return invalidArguments(message) }
            let range = characterRange(
                in: object.text,
                utf16Range: selection.utf16Range)
            return reply(message) {
                let first = $0.int32(Int32(clamping: range.lowerBound))
                guard first >= 0 else { return first }
                return $0.int32(Int32(clamping: range.upperBound))
            }
        case "SetSelection":
            guard readInt32(message) == 0,
                  let start = readInt32(message),
                  let end = readInt32(message),
                  let id = object.id
            else { return invalidArguments(message) }
            let lower = utf16Offset(
                in: object.text,
                characterOffset: Int(start))
            let upper = utf16Offset(
                in: object.text,
                characterOffset: Int(end))
            let accepted = onAction?(.init(
                target: id,
                action: .setSelection,
                selection: .init(
                    utf16Range: min(lower, upper)..<max(lower, upper)))) ?? false
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.text,
                member: member)
        }
    }

    func handleEditableText(
        _ message: SDBusMessage,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        guard !object.isSecure, let id = object.id else {
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.AccessDenied",
                text: "Secure text is not editable through accessibility")
        }
        switch member {
        case "SetTextContents":
            guard let text = readString(message) else {
                return invalidArguments(message)
            }
            let accepted = onAction?(.init(
                target: id,
                action: .setText,
                text: text)) ?? false
            return reply(message) { $0.boolean(accepted) }
        case "CopyText", "CutText":
            guard let start = readInt32(message),
                  let end = readInt32(message)
            else { return invalidArguments(message) }
            let lower = utf16Offset(
                in: object.text,
                characterOffset: Int(start))
            let upper = utf16Offset(
                in: object.text,
                characterOffset: Int(end))
            let selected = onAction?(.init(
                target: id,
                action: .setSelection,
                selection: .init(
                    utf16Range: min(lower, upper)..<max(lower, upper)))) ?? false
            let action: AccessibilityAction =
                member == "CopyText" ? .copy : .cut
            let accepted = selected
                && (onAction?(.init(target: id, action: action)) ?? false)
            return reply(message) { $0.boolean(accepted) }
        case "PasteText":
            guard let position = readInt32(message) else {
                return invalidArguments(message)
            }
            let offset = utf16Offset(
                in: object.text,
                characterOffset: Int(position))
            let selected = onAction?(.init(
                target: id,
                action: .setSelection,
                selection: .init(utf16Range: offset..<offset))) ?? false
            let accepted = selected
                && (onAction?(.init(target: id, action: .paste)) ?? false)
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.editableText,
                member: member)
        }
    }


    func textSlice(
        _ text: String,
        start: Int,
        end: Int
    ) -> String {
        let characters = Array(text)
        let lower = min(max(0, start), characters.count)
        let proposedEnd = end < 0 ? characters.count : end
        let upper = min(max(lower, proposedEnd), characters.count)
        return String(characters[lower..<upper])
    }

    func utf16Offset(
        in text: String,
        characterOffset: Int
    ) -> Int {
        let offset = min(max(0, characterOffset), text.count)
        let index = text.index(
            text.startIndex,
            offsetBy: offset)
        return index.utf16Offset(in: text)
    }

    func characterRange(
        in text: String,
        utf16Range: Range<Int>
    ) -> Range<Int> {
        func characterOffset(_ utf16Offset: Int) -> Int {
            let bounded = min(
                max(0, utf16Offset),
                text.utf16.count)
            let utf16Index = text.utf16.index(
                text.utf16.startIndex,
                offsetBy: bounded)
            guard let index = String.Index(
                utf16Index,
                within: text)
            else { return text.count }
            return text.distance(from: text.startIndex, to: index)
        }
        let lower = characterOffset(utf16Range.lowerBound)
        let upper = characterOffset(utf16Range.upperBound)
        return min(lower, upper)..<max(lower, upper)
    }

}
