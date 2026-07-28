import NucleusLinuxDBus
import NucleusUI

extension AtSPIService {
    // MARK: - Message dispatch

    func handle(_ message: SDBusMessage) -> Int32 {
        let path = message.path
        let interface = message.interface
        let member = message.member
        guard let object = model.objects[path] else {
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.UnknownObject",
                text: "No accessible object exists at \(path)")
        }
        if let expected = AtSPIWireContract.expectedInputSignature(
            interface: interface,
            member: member),
           messageSignature(message) != expected
        {
            return invalidArguments(message)
        }
        if interface.hasPrefix("org.a11y.atspi."),
           !object.interfaces.contains(interface)
        {
            return unknownInterface(message, interface: interface)
        }

        switch interface {
        case "org.freedesktop.DBus.Properties":
            return handleProperties(message, object: object, member: member)
        case "org.freedesktop.DBus.Introspectable":
            guard member == "Introspect" else {
                return unknownMethod(message, interface: interface, member: member)
            }
            return reply(message) {
                $0.string(AtSPIWireContract.introspectionXML(for: object))
            }
        case AtSPIInterface.accessible:
            return handleAccessible(message, object: object, member: member)
        case AtSPIInterface.action:
            return handleAction(message, object: object, member: member)
        case AtSPIInterface.application:
            return handleApplication(message, object: object, member: member)
        case AtSPIInterface.component:
            return handleComponent(message, object: object, member: member)
        case AtSPIInterface.editableText:
            return handleEditableText(message, object: object, member: member)
        case AtSPIInterface.selection:
            return handleSelection(message, object: object, member: member)
        case AtSPIInterface.text:
            return handleText(message, object: object, member: member)
        case AtSPIInterface.value:
            return handleValue(message, object: object, member: member)
        default:
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.UnknownInterface",
                text: "Unsupported interface \(interface)")
        }
    }

    func handleProperties(
        _ message: SDBusMessage,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        switch member {
        case "Get":
            guard let interface = readString(message),
                  let property = readString(message),
                  object.interfaces.contains(interface),
                  let value = propertyValue(
                    object: object,
                    interface: interface,
                    property: property)
            else {
                return replyError(
                    message,
                    name: "org.freedesktop.DBus.Error.InvalidArgs",
                    text: "Unknown AT-SPI property")
            }
            return reply(message) { value.appendVariant(to: &$0) }
        case "GetAll":
            guard let interface = readString(message) else {
                return invalidArguments(message)
            }
            guard object.interfaces.contains(interface) else {
                return unknownInterface(message, interface: interface)
            }
            let values = allProperties(
                object: object,
                interface: interface)
            return reply(message) { writer in
                writer.dictionary(values)
            }
        case "Set":
            guard let interface = readString(message),
                  let property = readString(message)
            else { return invalidArguments(message) }
            guard object.interfaces.contains(interface) else {
                return unknownInterface(message, interface: interface)
            }
            if interface == AtSPIInterface.application,
               property == "Id",
               let value = readVariantInt32(message)
            {
                applicationID = value
                return reply(message) { _ in 0 }
            }
            if interface == AtSPIInterface.value,
               property == "CurrentValue",
               let value = readVariantDouble(message),
               let id = object.id
            {
                let accepted = onAction?(.init(
                    target: id,
                    action: .setValue,
                    value: value)) ?? false
                return accepted
                    ? reply(message) { _ in 0 }
                    : actionFailed(message)
            }
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.PropertyReadOnly",
                text: "\(interface).\(property) is read-only")
        default:
            return unknownMethod(
                message,
                interface: "org.freedesktop.DBus.Properties",
                member: member)
        }
    }

}
