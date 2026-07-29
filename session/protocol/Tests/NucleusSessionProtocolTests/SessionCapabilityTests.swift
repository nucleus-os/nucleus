import FoundationEssentials
import NucleusSessionProtocol
import Testing

@Suite struct SessionCapabilityTests {
    @Test func declarationRoundTripsWithStableDefaults() throws {
        let declaration = try SessionCapabilityDeclaration(
            identifier: "android.runtime",
            executable: "/usr/libexec/nucleus-android-runtime")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(declaration)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(
            SessionCapabilityDeclaration.self,
            from: data) == declaration)
        #expect(declaration.restartPolicy == .onFailure)
        #expect(declaration.maximumRestarts == 3)
    }

    @Test func declarationRejectsUntrustedProcessShape() throws {
        #expect(throws: SessionCapabilityDeclarationFailure.self) {
            _ = try SessionCapabilityDeclaration(
                identifier: "../android",
                executable: "/usr/bin/true")
        }
        #expect(throws: SessionCapabilityDeclarationFailure.self) {
            _ = try SessionCapabilityDeclaration(
                identifier: "android.runtime",
                executable: "relative/runtime")
        }
        #expect(throws: SessionCapabilityDeclarationFailure.self) {
            _ = try SessionCapabilityDeclaration(
                identifier: "android.runtime",
                executable: "/usr/bin/true",
                arguments: [String(repeating: "x", count: 4_097)])
        }
        #expect(throws: SessionCapabilityDeclarationFailure.self) {
            _ = try SessionCapabilityDeclaration(
                identifier: "android.runtime",
                executable: "/usr/bin/true",
                maximumRestarts: 17)
        }
    }

    @Test func decodingEnforcesTheSameValidation() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let bytes = Data("""
            {
              "identifier": "android/runtime",
              "executable": "/usr/bin/true"
            }
            """.utf8)
        #expect(throws: SessionCapabilityDeclarationFailure.self) {
            _ = try decoder.decode(
                SessionCapabilityDeclaration.self,
                from: bytes)
        }
    }
}
