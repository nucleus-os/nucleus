import Foundation

/// A decoded JSON tree, used only for key auditing.
///
/// The typed model decodes through `Codable` and never touches this. It exists
/// so an unknown key — a typo, or a setting from a newer version — can be
/// reported instead of silently ignored, which is what `Codable` does by
/// default and is the wrong behavior for a file a person edits by hand.
///
/// Deliberately not `Any`: a value tree that crosses actor boundaries has to be
/// `Sendable`, and `JSONSerialization`'s output is not.
package enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    package init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var object: [String: JSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(
                    JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !container.isAtEnd {
                array.append(try container.decode(JSONValue.self))
            }
            self = .array(array)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}

/// A `CodingKey` that accepts any name, so `allKeys` reports what the file
/// actually contains rather than only what the model recognizes.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
