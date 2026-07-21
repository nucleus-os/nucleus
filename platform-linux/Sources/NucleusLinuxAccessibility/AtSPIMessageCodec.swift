private let dbusTypeArray = CChar(UInt8(ascii: "a"))
private let dbusTypeDictEntry = CChar(UInt8(ascii: "e"))
private let dbusTypeStruct = CChar(UInt8(ascii: "r"))
private let dbusTypeVariant = CChar(UInt8(ascii: "v"))

import NucleusLinuxDBus
import NucleusUI

/// D-Bus geometry is signed 32-bit. Treat non-finite semantic geometry as a
/// bounded wire value instead of routing it through `Int(Double)`, which traps
/// before `Int32(clamping:)` gets a chance to clamp it.
func atSPIWireInt32(_ value: Double) -> Int32 {
    guard !value.isNaN else { return 0 }
    guard value > Double(Int32.min) else { return .min }
    guard value < Double(Int32.max) else { return .max }
    return Int32(value.rounded(.towardZero))
}

extension AtSPIService {
    // MARK: - Helpers

    func reply(
        _ call: SDBusMessage,
        _ body: (inout SDBusMessageWriter) -> Int32
    ) -> Int32 {
        call.reply(body)
    }

    func replyError(
        _ call: SDBusMessage,
        name: String,
        text: String
    ) -> Int32 {
        call.replyError(name: name, message: text)
    }

    func invalidArguments(_ call: SDBusMessage) -> Int32 {
        replyError(
            call,
            name: "org.freedesktop.DBus.Error.InvalidArgs",
            text: "The AT-SPI method arguments are invalid")
    }

    func actionFailed(_ call: SDBusMessage) -> Int32 {
        replyError(
            call,
            name: "org.a11y.atspi.Error.Failed",
            text: "The accessibility action was rejected")
    }

    func unknownMethod(
        _ call: SDBusMessage,
        interface: String,
        member: String
    ) -> Int32 {
        replyError(
            call,
            name: "org.freedesktop.DBus.Error.UnknownMethod",
            text: "Unsupported method \(interface).\(member)")
    }

    func unknownInterface(
        _ call: SDBusMessage,
        interface: String
    ) -> Int32 {
        replyError(
            call,
            name: "org.freedesktop.DBus.Error.UnknownInterface",
            text: "Object does not implement \(interface)")
    }

    func messageSignature(_ message: SDBusMessage) -> String {
        message.signature
    }

    func readString(_ message: SDBusMessage) -> String? {
        message.readString()
    }

    func readInt32(_ message: SDBusMessage) -> Int32? {
        message.readInt32()
    }

    func readUInt32(_ message: SDBusMessage) -> UInt32? {
        message.readUInt32()
    }

    func readDouble(_ message: SDBusMessage) -> Double? {
        message.readDouble()
    }

    func readVariantInt32(_ message: SDBusMessage) -> Int32? {
        guard message.enterContainer(type: dbusTypeVariant, signature: "i")
        else { return nil }
        defer { _ = message.exitContainer() }
        return readInt32(message)
    }

    func readVariantDouble(_ message: SDBusMessage) -> Double? {
        guard message.enterContainer(type: dbusTypeVariant, signature: "d")
        else { return nil }
        defer { _ = message.exitContainer() }
        return readDouble(message)
    }

    func readObjectReference(
        _ message: SDBusMessage
    ) -> (String, String)? {
        guard message.enterContainer(type: dbusTypeStruct, signature: "so")
        else { return nil }
        defer { _ = message.exitContainer() }
        guard let name = message.readString(),
              let path = message.readObjectPath()
        else { return nil }
        return (name, path)
    }

}

extension SDBusMessageWriter {
    mutating func dictionary(
        _ values: [(String, AtSPIService.PropertyValue)]
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "{sv}") { writer in
            for (name, value) in values {
                let result = writer.container(
                    type: dbusTypeDictEntry,
                    signature: "sv"
                ) {
                    let first = $0.string(name)
                    guard first >= 0 else { return first }
                    return value.appendVariant(to: &$0)
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func relationSet(
        _ relations: [UInt32: [String]],
        busName: String
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "(ua(so))") { writer in
            for relation in relations.keys.sorted() {
                let result = writer.structValue(signature: "ua(so)") {
                    let first = $0.uint32(relation)
                    guard first >= 0 else { return first }
                    return $0.objectReferenceArray(
                        relations[relation] ?? [],
                        busName: busName)
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func actionDescriptions(
        _ actions: [(
            name: String,
            description: String,
            keyBinding: String
        )]
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "(sss)") { writer in
            for action in actions {
                let result = writer.structValue(signature: "sss") {
                    let first = $0.string(action.name)
                    guard first >= 0 else { return first }
                    let second = $0.string(action.description)
                    guard second >= 0 else { return second }
                    return $0.string(action.keyBinding)
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func rect(_ rect: Rect) -> Int32 {
        let values = [
            atSPIWireInt32(rect.origin.x),
            atSPIWireInt32(rect.origin.y),
            atSPIWireInt32(rect.size.width),
            atSPIWireInt32(rect.size.height),
        ]
        for value in values {
            let result = int32(value)
            guard result >= 0 else { return result }
        }
        return 0
    }
}
