import FoundationEssentials
import Testing
@testable import NucleusConfig

// Guards on the value the unknown-key audit derives its key set from.
//
// The audit works by encoding `schemaReference` and treating the resulting keys
// as the complete valid set. That is only true if the reference actually
// contains every key — and `Encodable` omits a nil optional and yields nothing
// for an empty array, so either one silently removes keys from the audit and a
// typo on them passes unnoticed. Nothing about adding a field forces the
// reference to be updated, so these tests do the forcing.
@Suite struct SchemaReferenceTests {
    /// A defect found while walking the reference.
    private struct Gap: CustomStringConvertible {
        var path: String
        var problem: String
        var description: String { "\(path): \(problem)" }
    }

    /// Walk a value, reporting anything that would erase keys from the audit.
    ///
    /// Collections recurse into their first element only. The reference needs
    /// *an* element so element keys are discoverable; requiring every element
    /// to be fully populated would be wrong, because a tagged union like
    /// `BindAction` legitimately has elements carrying different keys — the
    /// auditor unions across them, and `parametersOfEveryActionShapeAuditAsKnown`
    /// covers that case directly.
    private func gaps(
        in value: Any, path: String = "", depth: Int = 0
    ) -> [Gap] {
        guard depth < 12 else { return [] }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let wrapped = mirror.children.first?.value else {
                return [Gap(
                    path: path,
                    problem: "is nil, so its key is absent from the audit")]
            }
            return gaps(in: wrapped, path: path, depth: depth + 1)
        case .collection, .set:
            guard let first = mirror.children.first?.value else {
                return [Gap(
                    path: path,
                    problem: "is empty, so its element keys are unaudited")]
            }
            return gaps(in: first, path: path + "[0]", depth: depth + 1)
        case .dictionary:
            guard mirror.children.first != nil else {
                return [Gap(
                    path: path,
                    problem: "is empty, so its entry keys are unaudited")]
            }
            return []
        default:
            // A leaf, or a struct to descend into. An empty string is fine —
            // `name: ""` in the outputs exemplar is a deliberate placeholder,
            // and String is not a `.collection` to Mirror.
            return mirror.children.flatMap { child -> [Gap] in
                guard let label = child.label else { return [] }
                let childPath = path.isEmpty ? label : "\(path).\(label)"
                return gaps(
                    in: child.value, path: childPath, depth: depth + 1)
            }
        }
    }

    @Test func theSchemaReferenceCarriesEveryKeyItClaimsTo() {
        // Adding a field with a nil default, or an array-valued section that
        // ships empty, fails here rather than silently disabling the audit for
        // it. That has already been needed twice: once for `outputs`, once for
        // `adaptive_sync`.
        let found = gaps(in: NucleusConfiguration.schemaReference)
        #expect(found.isEmpty, "\(found.map(\.description))")
    }

    @Test func theShippedDefaultsAreNotUsedAsTheReference() {
        // `defaults` is deliberately honest — `outputs` really is empty — which
        // is exactly why it cannot be the audit reference. If these ever became
        // the same value, auditing would silently lose array element keys.
        #expect(NucleusConfiguration.defaults.outputs.isEmpty)
        #expect(!NucleusConfiguration.schemaReference.outputs.isEmpty)
    }

    @Test func everyReferenceKeySurvivesEncoding() throws {
        // The audit reads keys out of encoded JSON, so a field that encodes to
        // nothing is invisible however populated the Swift value is.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(NucleusConfiguration.schemaReference)
        let text = String(decoding: data, as: UTF8.self)
        for key in [
            "config_version", "input", "binds", "outputs", "shell",
            "adaptive_sync", "scale", "position",
        ] {
            #expect(text.contains("\"\(key)\""), "\(key) missing from reference")
        }
    }
}

// The audit compares against the resolved configuration, but the file is
// decoded into the Part configuration. Those two mirror each other by
// discipline, not by construction — a field added to one and not the other
// would make the audit wrong about a key that really is or is not accepted.
@Suite struct ResolvedAndPartShapeTests {
    /// Every property path in a value, as dotted labels.
    ///
    /// Collections contribute their first element's shape without an index
    /// component: what matters is the element's structure, not how many there
    /// are. Optionals contribute their wrapped shape.
    private func paths(
        of value: Any, prefix: String = "", depth: Int = 0
    ) -> Set<String> {
        guard depth < 12 else { return [] }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let wrapped = mirror.children.first?.value else { return [] }
            return paths(of: wrapped, prefix: prefix, depth: depth + 1)
        case .collection, .set:
            guard let first = mirror.children.first?.value else { return [] }
            return paths(of: first, prefix: prefix, depth: depth + 1)
        default:
            var found: Set<String> = []
            for child in mirror.children {
                guard let label = child.label else { continue }
                let path = prefix.isEmpty ? label : "\(prefix).\(label)"
                found.insert(path)
                found.formUnion(
                    paths(of: child.value, prefix: path, depth: depth + 1))
            }
            return found
        }
    }

    @Test func theResolvedAndPartConfigurationsHaveTheSameShape() throws {
        // Populate the Part from the reference, so nested Part values exist to
        // compare against rather than being nil and unreachable.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try encoder.encode(NucleusConfiguration.schemaReference)
        let part = try decoder.decode(
            NucleusConfigurationPart.self, from: data)

        let resolved = paths(of: NucleusConfiguration.schemaReference)
        let mirrored = paths(of: part)
        // Both directions matter: a field only in the resolved type makes the
        // audit accept a key the file cannot actually set, and a field only in
        // Part makes it reject one the file legitimately can.
        let onlyResolved = resolved.subtracting(mirrored).sorted()
        let onlyPart = mirrored.subtracting(resolved).sorted()
        #expect(onlyResolved.isEmpty, "only in resolved: \(onlyResolved)")
        #expect(onlyPart.isEmpty, "only in Part: \(onlyPart)")
    }

    @Test func theRootSectionsMatchExactly() {
        // The cheap half of the same invariant, independent of decoding: a new
        // top-level section added to one side and not the other fails here.
        let resolved = Set(
            Mirror(reflecting: NucleusConfiguration.schemaReference)
                .children.compactMap(\.label))
        let part = Set(
            Mirror(reflecting: NucleusConfigurationPart())
                .children.compactMap(\.label))
        #expect(
            resolved == part,
            "resolved \(resolved.sorted()) vs part \(part.sorted())")
    }
}
