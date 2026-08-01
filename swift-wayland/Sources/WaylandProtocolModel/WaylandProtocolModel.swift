import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

package struct WaylandDescription: Equatable, Sendable {
    package let summary: String?
    package let body: String?

    package init(summary: String?, body: String?) {
        self.summary = summary
        self.body = body
    }
}

package struct WaylandArgument: Equatable, Sendable {
    package let name: String
    package let type: String
    package let interface: String?
    package let allowNull: Bool
    package let enumName: String?
    package let summary: String?

    package init(
        name: String,
        type: String,
        interface: String?,
        allowNull: Bool,
        enumName: String?,
        summary: String?
    ) {
        self.name = name
        self.type = type
        self.interface = interface
        self.allowNull = allowNull
        self.enumName = enumName
        self.summary = summary
    }
}

package struct WaylandMessage: Equatable, Sendable {
    package let name: String
    package let isDestructor: Bool
    package let since: Int
    package var arguments: [WaylandArgument]
    package var description: WaylandDescription?

    package init(
        name: String,
        isDestructor: Bool,
        since: Int,
        arguments: [WaylandArgument] = [],
        description: WaylandDescription? = nil
    ) {
        self.name = name
        self.isDestructor = isDestructor
        self.since = since
        self.arguments = arguments
        self.description = description
    }
}

package struct WaylandEnumEntry: Equatable, Sendable {
    package let name: String
    package let value: String
    package let summary: String?
    package let since: Int
    package let deprecatedSince: Int?

    package init(
        name: String,
        value: String,
        summary: String?,
        since: Int,
        deprecatedSince: Int?
    ) {
        self.name = name
        self.value = value
        self.summary = summary
        self.since = since
        self.deprecatedSince = deprecatedSince
    }
}

package struct WaylandEnumeration: Equatable, Sendable {
    package let name: String
    package let isBitfield: Bool
    package let since: Int
    package var entries: [WaylandEnumEntry]
    package var description: WaylandDescription?

    package init(
        name: String,
        isBitfield: Bool,
        since: Int,
        entries: [WaylandEnumEntry] = [],
        description: WaylandDescription? = nil
    ) {
        self.name = name
        self.isBitfield = isBitfield
        self.since = since
        self.entries = entries
        self.description = description
    }
}

package struct WaylandInterface: Equatable, Sendable {
    package let name: String
    package let version: Int
    package var requests: [WaylandMessage]
    package var events: [WaylandMessage]
    package var enumerations: [WaylandEnumeration]
    package var description: WaylandDescription?

    package var requestCount: Int { requests.count }

    package init(
        name: String,
        version: Int,
        requests: [WaylandMessage] = [],
        events: [WaylandMessage] = [],
        enumerations: [WaylandEnumeration] = [],
        description: WaylandDescription? = nil
    ) {
        self.name = name
        self.version = version
        self.requests = requests
        self.events = events
        self.enumerations = enumerations
        self.description = description
    }
}

package struct WaylandProtocol: Equatable, Sendable {
    package var name: String
    package var xmlPath: String
    package var interfaces: [WaylandInterface]
    package var definedInterfaces: Set<String>
    package var referencedInterfaces: Set<String>

    package init(
        name: String = "",
        xmlPath: String = "",
        interfaces: [WaylandInterface] = [],
        definedInterfaces: Set<String> = [],
        referencedInterfaces: Set<String> = []
    ) {
        self.name = name
        self.xmlPath = xmlPath
        self.interfaces = interfaces
        self.definedInterfaces = definedInterfaces
        self.referencedInterfaces = referencedInterfaces
    }
}

package enum WaylandProtocolParseError: Error, Equatable, CustomStringConvertible {
    case invalidXML(path: String, message: String)
    case missingAttribute(path: String, element: String, attribute: String)
    case invalidInteger(path: String, element: String, attribute: String, value: String)
    case nestedMessage(path: String, interface: String)

    package var description: String {
        switch self {
        case .invalidXML(let path, let message):
            return "\(path): invalid Wayland protocol XML: \(message)"
        case .missingAttribute(let path, let element, let attribute):
            return "\(path): <\(element)> is missing required '\(attribute)'"
        case .invalidInteger(let path, let element, let attribute, let value):
            return "\(path): <\(element)> has invalid \(attribute) value '\(value)'"
        case .nestedMessage(let path, let interface):
            return "\(path): \(interface) contains nested request/event elements"
        }
    }
}

package enum WaylandProtocolParser {
    package static func parse(path: String) throws -> WaylandProtocol {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw WaylandProtocolParseError.invalidXML(
                path: path,
                message: "file could not be read")
        }
        return try parse(data: data, path: path)
    }

    package static func parse(data: Data, path: String = "<memory>") throws -> WaylandProtocol {
        let delegate = ParserDelegate(path: path)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            if let failure = delegate.failure {
                throw failure
            }
            throw WaylandProtocolParseError.invalidXML(
                path: path,
                message: parser.parserError?.localizedDescription ?? "unknown parser failure")
        }
        if let failure = delegate.failure {
            throw failure
        }
        var protocolDocument = delegate.protocolDocument
        protocolDocument.xmlPath = path
        return protocolDocument
    }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    private enum MessageScope {
        case none
        case request(interface: Int, message: Int)
        case event(interface: Int, message: Int)
    }

    private enum DescriptionTarget {
        case interface(Int)
        case request(interface: Int, message: Int)
        case event(interface: Int, message: Int)
        case enumeration(interface: Int, enumeration: Int)
    }

    var protocolDocument = WaylandProtocol()
    var failure: WaylandProtocolParseError?

    private let path: String
    private var messageScope: MessageScope = .none
    private var currentEnumeration: (interface: Int, enumeration: Int)?
    private var descriptionTarget: DescriptionTarget?
    private var descriptionSummary: String?
    private var descriptionBody = ""

    init(path: String) {
        self.path = path
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        guard failure == nil else { return }
        do {
            switch elementName {
            case "protocol":
                protocolDocument.name = try required(
                    "name", in: attributes, element: elementName)
            case "interface":
                let name = try required("name", in: attributes, element: elementName)
                let version = try integer(
                    "version", in: attributes, element: elementName, default: 1)
                protocolDocument.interfaces.append(
                    WaylandInterface(name: name, version: version))
                protocolDocument.definedInterfaces.insert(name)
            case "request":
                try beginMessage(
                    elementName: elementName,
                    attributes: attributes,
                    isRequest: true)
            case "event":
                try beginMessage(
                    elementName: elementName,
                    attributes: attributes,
                    isRequest: false)
            case "arg":
                try appendArgument(attributes)
            case "enum":
                try beginEnumeration(attributes)
            case "entry":
                try appendEntry(attributes)
            case "description":
                beginDescription(attributes)
            default:
                break
            }
        } catch let parseError as WaylandProtocolParseError {
            failure = parseError
            parser.abortParsing()
        } catch {
            failure = .invalidXML(path: path, message: String(describing: error))
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard descriptionTarget != nil else { return }
        descriptionBody += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "request", "event":
            messageScope = .none
        case "enum":
            currentEnumeration = nil
        case "description":
            finishDescription()
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        parseErrorOccurred parseError: Error
    ) {
        guard failure == nil else { return }
        failure = .invalidXML(path: path, message: parseError.localizedDescription)
    }

    private func beginMessage(
        elementName: String,
        attributes: [String: String],
        isRequest: Bool
    ) throws {
        guard case .none = messageScope else {
            throw WaylandProtocolParseError.nestedMessage(
                path: path,
                interface: currentInterfaceName)
        }
        let interface = try currentInterfaceIndex(element: elementName)
        let message = WaylandMessage(
            name: try required("name", in: attributes, element: elementName),
            isDestructor: attributes["type"] == "destructor",
            since: try integer(
                "since", in: attributes, element: elementName, default: 1))
        if isRequest {
            protocolDocument.interfaces[interface].requests.append(message)
            messageScope = .request(
                interface: interface,
                message: protocolDocument.interfaces[interface].requests.count - 1)
        } else {
            protocolDocument.interfaces[interface].events.append(message)
            messageScope = .event(
                interface: interface,
                message: protocolDocument.interfaces[interface].events.count - 1)
        }
    }

    private func appendArgument(_ attributes: [String: String]) throws {
        let argument = WaylandArgument(
            name: try required("name", in: attributes, element: "arg"),
            type: try required("type", in: attributes, element: "arg"),
            interface: attributes["interface"],
            allowNull: attributes["allow-null"] == "true",
            enumName: attributes["enum"],
            summary: attributes["summary"])
        if let interface = argument.interface {
            protocolDocument.referencedInterfaces.insert(interface)
        }
        switch messageScope {
        case .none:
            throw WaylandProtocolParseError.invalidXML(
                path: path,
                message: "<arg> appears outside a request or event")
        case .request(let interface, let message):
            protocolDocument.interfaces[interface].requests[message].arguments.append(argument)
        case .event(let interface, let message):
            protocolDocument.interfaces[interface].events[message].arguments.append(argument)
        }
    }

    private func beginEnumeration(_ attributes: [String: String]) throws {
        let interface = try currentInterfaceIndex(element: "enum")
        let enumeration = WaylandEnumeration(
            name: try required("name", in: attributes, element: "enum"),
            isBitfield: attributes["bitfield"] == "true",
            since: try integer("since", in: attributes, element: "enum", default: 1))
        protocolDocument.interfaces[interface].enumerations.append(enumeration)
        currentEnumeration = (
            interface,
            protocolDocument.interfaces[interface].enumerations.count - 1
        )
    }

    private func appendEntry(_ attributes: [String: String]) throws {
        guard let currentEnumeration else {
            throw WaylandProtocolParseError.invalidXML(
                path: path,
                message: "<entry> appears outside an enum")
        }
        let deprecatedSince: Int?
        if let raw = attributes["deprecated-since"] {
            deprecatedSince = try parsedInteger(
                raw,
                element: "entry",
                attribute: "deprecated-since")
        } else {
            deprecatedSince = nil
        }
        protocolDocument.interfaces[currentEnumeration.interface]
            .enumerations[currentEnumeration.enumeration].entries.append(
                WaylandEnumEntry(
                    name: try required("name", in: attributes, element: "entry"),
                    value: try required("value", in: attributes, element: "entry"),
                    summary: attributes["summary"],
                    since: try integer(
                        "since", in: attributes, element: "entry", default: 1),
                    deprecatedSince: deprecatedSince))
    }

    private func beginDescription(_ attributes: [String: String]) {
        let target: DescriptionTarget?
        switch messageScope {
        case .request(let interface, let message):
            target = .request(interface: interface, message: message)
        case .event(let interface, let message):
            target = .event(interface: interface, message: message)
        case .none:
            if let currentEnumeration {
                target = .enumeration(
                    interface: currentEnumeration.interface,
                    enumeration: currentEnumeration.enumeration)
            } else if !protocolDocument.interfaces.isEmpty {
                target = .interface(protocolDocument.interfaces.count - 1)
            } else {
                target = nil
            }
        }
        descriptionTarget = target
        descriptionSummary = attributes["summary"]
        descriptionBody = ""
    }

    private func finishDescription() {
        guard let descriptionTarget else { return }
        let normalizedBody =
            descriptionBody
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let description = WaylandDescription(
            summary: descriptionSummary,
            body: normalizedBody.isEmpty ? nil : normalizedBody)
        switch descriptionTarget {
        case .interface(let interface):
            protocolDocument.interfaces[interface].description = description
        case .request(let interface, let message):
            protocolDocument.interfaces[interface].requests[message].description = description
        case .event(let interface, let message):
            protocolDocument.interfaces[interface].events[message].description = description
        case .enumeration(let interface, let enumeration):
            protocolDocument.interfaces[interface]
                .enumerations[enumeration].description = description
        }
        self.descriptionTarget = nil
        descriptionSummary = nil
        descriptionBody = ""
    }

    private var currentInterfaceName: String {
        protocolDocument.interfaces.last?.name ?? "<no interface>"
    }

    private func currentInterfaceIndex(element: String) throws -> Int {
        guard !protocolDocument.interfaces.isEmpty else {
            throw WaylandProtocolParseError.invalidXML(
                path: path,
                message: "<\(element)> appears outside an interface")
        }
        return protocolDocument.interfaces.count - 1
    }

    private func required(
        _ attribute: String,
        in attributes: [String: String],
        element: String
    ) throws -> String {
        guard let value = attributes[attribute], !value.isEmpty else {
            throw WaylandProtocolParseError.missingAttribute(
                path: path,
                element: element,
                attribute: attribute)
        }
        return value
    }

    private func integer(
        _ attribute: String,
        in attributes: [String: String],
        element: String,
        default defaultValue: Int
    ) throws -> Int {
        guard let value = attributes[attribute] else { return defaultValue }
        return try parsedInteger(
            value,
            element: element,
            attribute: attribute)
    }

    private func parsedInteger(
        _ value: String,
        element: String,
        attribute: String
    ) throws -> Int {
        guard let integer = Int(value), integer > 0 else {
            throw WaylandProtocolParseError.invalidInteger(
                path: path,
                element: element,
                attribute: attribute,
                value: value)
        }
        return integer
    }
}
