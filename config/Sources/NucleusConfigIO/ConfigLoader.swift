import Foundation
import NucleusConfig
import NucleusConfigSyntax

/// The result of reading one configuration source.
public enum ConfigLoadOutcome: Sendable {
    /// Usable configuration. Warnings do not block it — an ignored unknown key
    /// should not cost a user their whole desktop configuration.
    case loaded(NucleusConfiguration, warnings: [ConfigDiagnostic])
    /// Unusable. The caller keeps whatever it already had and surfaces these.
    case failed([ConfigDiagnostic])
}

/// Reads configuration text into resolved values.
///
/// The division of labor is deliberate. `NucleusConfigSyntax` owns positional
/// defects, because Foundation reports every syntax error as one
/// undifferentiated "not valid JSON" with no offset. `JSONDecoder` owns semantic
/// defects, because its coding path (`input.touchpad.accel_speed`) is a better
/// diagnostic than any byte offset would be.
public enum ConfigLoader {
    public static func load(text: String) -> ConfigLoadOutcome {
        let source = ConfigSource(text: text)

        let prepared: [UInt8]
        do {
            prepared = try ConfigSyntax.prepare(source)
        } catch {
            return .failed([.from(error, in: source)])
        }

        let data = Data(prepared)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let part: NucleusConfigurationPart
        do {
            part = try decoder.decode(NucleusConfigurationPart.self, from: data)
        } catch let error as DecodingError {
            return .failed([diagnostic(for: error, in: source)])
        } catch {
            return .failed([
                ConfigDiagnostic(
                    severity: .error, message: "\(error)")
            ])
        }

        var warnings = auditUnknownKeys(in: data)
        if let declared = part.configVersion,
            declared > NucleusConfiguration.currentVersion
        {
            warnings.append(
                ConfigDiagnostic(
                    severity: .warning,
                    message: "config_version \(declared) is newer than this build "
                        + "understands (\(NucleusConfiguration.currentVersion)); "
                        + "unrecognized settings are ignored",
                    keyPath: ["config_version"]))
        }
        let resolved = NucleusConfiguration.defaults.applying(part)
        warnings.append(
            contentsOf: resolved.validate().map(ConfigDiagnostic.init))
        return .loaded(resolved, warnings: warnings)
    }

    // MARK: decode diagnostics

    private static func diagnostic(
        for error: DecodingError, in source: ConfigSource
    ) -> ConfigDiagnostic {
        switch error {
        case .keyNotFound(let key, let context):
            // The absent key is not in the coding path — it is the thing that
            // was missing — so append it, or the diagnostic points at the
            // enclosing object and leaves the user to guess.
            return ConfigDiagnostic(
                severity: .error,
                message: "missing required setting",
                keyPath: displayPath(context.codingPath + [key]))
        case .valueNotFound(_, let context):
            return ConfigDiagnostic(
                severity: .error,
                message: "value is null",
                keyPath: displayPath(context.codingPath))
        case .typeMismatch(_, let context),
            .dataCorrupted(let context):
            return ConfigDiagnostic(
                severity: .error,
                message: clean(context.debugDescription),
                keyPath: displayPath(context.codingPath))
        @unknown default:
            return ConfigDiagnostic(severity: .error, message: "\(error)")
        }
    }

    /// Foundation's messages are written for programmers. Trim the parts that
    /// only make sense if you can see the Swift types.
    ///
    /// Stdlib string operations only — `replacingOccurrences(of:with:)` and
    /// `range(of:)` come from full Foundation, which this package deliberately
    /// does not depend on.
    private static func clean(_ description: String) -> String {
        if description == "The given data was not valid JSON." {
            return "not valid JSON"
        }
        var text = description
        if text.hasPrefix("Expected to decode ") {
            text = "expected " + text.dropFirst("Expected to decode ".count)
        }
        text = text.replacing(" but found", with: ", found")
        if text.hasSuffix(" instead.") {
            text = String(text.dropLast(" instead.".count))
        }
        return text
    }

    /// Coding paths carry Swift property names; the file used snake_case. Show
    /// the user what they actually typed.
    private static func displayPath(_ path: [any CodingKey]) -> [String] {
        path.map { key in
            if let index = key.intValue { return "[\(index)]" }
            return snakeCased(key.stringValue)
        }
    }

    static func snakeCased(_ name: String) -> String {
        var output = ""
        for character in name {
            if character.isUppercase {
                if !output.isEmpty { output.append("_") }
                output.append(Character(character.lowercased()))
            } else {
                output.append(character)
            }
        }
        return output
    }

    // MARK: unknown key audit

    /// Report keys the model does not recognize.
    ///
    /// `Codable` ignores unknown keys silently, which for a hand-edited file
    /// turns a typo into a setting that mysteriously does nothing. The set of
    /// valid keys is derived by encoding the resolved defaults rather than kept
    /// as a hand-written manifest, so it cannot drift from the model.
    static func auditUnknownKeys(in data: Data) -> [ConfigDiagnostic] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        guard
            let referenceData = try? encoder.encode(
                NucleusConfiguration.schemaReference),
            let reference = try? decoder.decode(
                JSONValue.self, from: referenceData),
            let actual = try? decoder.decode(JSONValue.self, from: data)
        else { return [] }

        var diagnostics: [ConfigDiagnostic] = []
        walk(actual, against: reference, path: [], into: &diagnostics)
        return diagnostics
    }

    private static func walk(
        _ actual: JSONValue,
        against reference: JSONValue,
        path: [String],
        into diagnostics: inout [ConfigDiagnostic]
    ) {
        switch (actual, reference) {
        case (.object(let actualObject), .object(let referenceObject)):
            for key in actualObject.keys.sorted() {
                guard let referenceChild = referenceObject[key] else {
                    diagnostics.append(
                        ConfigDiagnostic(
                            severity: .warning,
                            message: "unknown setting; ignored",
                            keyPath: path + [key]))
                    continue
                }
                guard let actualChild = actualObject[key] else { continue }
                walk(
                    actualChild, against: referenceChild,
                    path: path + [key], into: &diagnostics)
            }
        case (.array(let actualArray), .array(let referenceArray)):
            // Element keys are audited against the *union* of every default
            // element, not against the first. An array of tagged unions — binds
            // being the case in point — has elements whose valid keys differ by
            // tag, so a single exemplar would flag `direction` as unknown just
            // because the first default happens to be a `launch`. The defaults
            // exercise every case, so their union is the complete key set.
            //
            // An empty defaults array yields no warnings for its elements; any
            // array-valued setting added later should ship default elements
            // covering each shape so this stays useful.
            guard !referenceArray.isEmpty else { return }
            let exemplar = Self.unioned(referenceArray)
            for (index, element) in actualArray.enumerated() {
                walk(
                    element, against: exemplar,
                    path: path + ["[\(index)]"], into: &diagnostics)
            }
        default:
            return
        }
    }

    /// Merge a reference array's elements into one value carrying every key any
    /// of them has, recursing so nested objects union too.
    private static func unioned(_ values: [JSONValue]) -> JSONValue {
        var merged: [String: JSONValue] = [:]
        var sawObject = false
        for value in values {
            guard case .object(let object) = value else { continue }
            sawObject = true
            for (key, child) in object {
                if let existing = merged[key] {
                    merged[key] = unioned([existing, child])
                } else {
                    merged[key] = child
                }
            }
        }
        // Non-object elements have no keys to audit; hand back the first so the
        // walk's type match still behaves.
        return sawObject ? .object(merged) : (values.first ?? .null)
    }
}
