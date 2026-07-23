import FoundationEssentials

/// Verifies downloaded inputs with the host's SHA-256 implementation.
///
/// The expected digest is compiled into the workspace tool. Fetching a digest
/// beside its payload would only repeat the payload transport's trust decision.
enum SHA256Verifier {
    #if os(macOS)
    static let executable = "shasum"

    private static func arguments(for file: URL) -> [String] {
        ["-a", "256", "-b", file.path]
    }
    #else
    static let executable = "sha256sum"

    private static func arguments(for file: URL) -> [String] {
        ["--binary", file.path]
    }
    #endif

    static func verify(
        _ file: URL,
        expectedDigest: String,
        context: WorkspaceContext
    ) throws {
        guard isDigest(expectedDigest) else {
            throw WorkspaceFailure.message(
                "invalid pinned SHA-256 digest for \(file.lastPathComponent)")
        }

        let output = try context.run(
            executable,
            arguments(for: file),
            capture: true)
        guard let actualDigest = output.split(whereSeparator: \Character.isWhitespace).first,
              isDigest(actualDigest)
        else {
            throw WorkspaceFailure.message(
                "could not parse SHA-256 digest for \(file.path)")
        }

        guard actualDigest.elementsEqual(expectedDigest) else {
            throw WorkspaceFailure.message(
                "SHA-256 mismatch for \(file.lastPathComponent): "
                    + "expected \(expectedDigest), got \(actualDigest)")
        }
    }

    private static func isDigest<S: StringProtocol>(_ value: S) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}
