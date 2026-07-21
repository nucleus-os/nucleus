import NucleusLinuxDBus
import NucleusUI

extension AtSPIService {
    // MARK: - Properties

    enum PropertyValue {
        case string(String)
        case int32(Int32)
        case uint32(UInt32)
        case double(Double)
        case objectReference(busName: String, path: String)

        func appendVariant(to writer: inout SDBusMessageWriter) -> Int32 {
            switch self {
            case .string(let value):
                return writer.variant(signature: "s") {
                    $0.string(value)
                }
            case .int32(let value):
                return writer.variant(signature: "i") {
                    $0.int32(value)
                }
            case .uint32(let value):
                return writer.variant(signature: "u") {
                    $0.uint32(value)
                }
            case .double(let value):
                return writer.variant(signature: "d") {
                    $0.double(value)
                }
            case .objectReference(let busName, let path):
                return writer.variant(signature: "(so)") {
                    $0.objectReference(
                        busName: busName,
                        path: path)
                }
            }
        }
    }

    func propertyValue(
        object: AtSPIExportedObject,
        interface: String,
        property: String
    ) -> PropertyValue? {
        switch (interface, property) {
        case (AtSPIInterface.accessible, "Name"):
            .string(object.name)
        case (AtSPIInterface.accessible, "Description"):
            .string(object.description)
        case (AtSPIInterface.accessible, "Parent"):
            .objectReference(
                busName: object.parentPath == nil ? "" : uniqueName,
                path: object.parentPath ?? AtSPIExportModel.nullPath)
        case (AtSPIInterface.accessible, "ChildCount"):
            .int32(Int32(clamping: object.childPaths.count))
        case (AtSPIInterface.accessible, "Locale"):
            .string(locale)
        case (AtSPIInterface.accessible, "AccessibleId"):
            .string(object.id?.pathComponent ?? "application")
        case (AtSPIInterface.accessible, "HelpText"):
            .string(object.description)
        case (AtSPIInterface.accessible, "version"):
            .uint32(2)
        case (AtSPIInterface.action, "NActions"):
            .int32(Int32(clamping: object.parameterlessActions.count))
        case (AtSPIInterface.action, "version"):
            .uint32(1)
        case (AtSPIInterface.application, "ToolkitName"):
            .string("NucleusUI")
        case (AtSPIInterface.application, "ToolkitVersion"):
            .string("0.1")
        case (AtSPIInterface.application, "Version"):
            .string("0.1")
        case (AtSPIInterface.application, "AtspiVersion"):
            .string("2.1")
        case (AtSPIInterface.application, "InterfaceVersion"):
            .uint32(1)
        case (AtSPIInterface.application, "Id"):
            .int32(applicationID)
        case (AtSPIInterface.component, "version"):
            .uint32(1)
        case (AtSPIInterface.text, "CharacterCount"):
            .int32(Int32(clamping: object.text.count))
        case (AtSPIInterface.text, "CaretOffset"):
            .int32(Int32(clamping: characterRange(
                in: object.text,
                utf16Range: object.textSelection?.utf16Range ?? 0..<0
            ).upperBound))
        case (AtSPIInterface.text, "version"):
            .uint32(1)
        case (AtSPIInterface.editableText, "version"):
            .uint32(1)
        case (AtSPIInterface.selection, "version"):
            .uint32(1)
        case (AtSPIInterface.value, "MinimumValue"):
            object.range.map { .double($0.minimum) }
        case (AtSPIInterface.value, "MaximumValue"):
            object.range.map { .double($0.maximum) }
        case (AtSPIInterface.value, "MinimumIncrement"):
            object.range.map { .double($0.increment ?? 0) }
        case (AtSPIInterface.value, "CurrentValue"):
            object.range.map { .double($0.current) }
        case (AtSPIInterface.value, "Text"):
            .string(object.valueText)
        case (AtSPIInterface.value, "version"):
            .uint32(1)
        default:
            nil
        }
    }

    func allProperties(
        object: AtSPIExportedObject,
        interface: String
    ) -> [(String, PropertyValue)] {
        let names: [String] = switch interface {
        case AtSPIInterface.accessible:
            ["Name", "Description", "Parent", "ChildCount", "Locale",
             "AccessibleId", "HelpText", "version"]
        case AtSPIInterface.action:
            ["NActions", "version"]
        case AtSPIInterface.application:
            ["ToolkitName", "ToolkitVersion", "Version", "AtspiVersion",
             "InterfaceVersion", "Id"]
        case AtSPIInterface.component:
            ["version"]
        case AtSPIInterface.text:
            ["CharacterCount", "CaretOffset", "version"]
        case AtSPIInterface.editableText, AtSPIInterface.selection:
            ["version"]
        case AtSPIInterface.value:
            ["MinimumValue", "MaximumValue", "MinimumIncrement",
             "CurrentValue", "Text", "version"]
        default:
            []
        }
        return names.compactMap { name in
            propertyValue(
                object: object,
                interface: interface,
                property: name).map { (name, $0) }
        }
    }

}
