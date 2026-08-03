import Foundation
package import NucleusConfig

/// Writes resolved configuration back out as JSON.
///
/// Two uses, and both matter. It backs "show me the effective configuration",
/// which is the only honest answer to *why is my touchpad behaving like this*
/// once defaults, file, and overrides have been layered. It also produces a
/// complete annotated starting file, so a user's first edit is against every
/// setting at its real default rather than a blank object.
package enum ConfigExport {
    /// Deterministically ordered, indented JSON with snake_case keys — the same
    /// spelling the loader accepts.
    package static func json(
        _ configuration: NucleusConfiguration
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        return String(decoding: data, as: UTF8.self)
    }
}
