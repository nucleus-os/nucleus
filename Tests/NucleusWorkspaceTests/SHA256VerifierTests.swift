import FoundationEssentials
import Testing
@testable import NucleusWorkspace

@Test
func sha256VerifierAcceptsAnExactDigestAndRejectsDifferentBytes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "nucleus-sha256-verifier-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixture = directory.appendingPathComponent("fixture")
    try Data("abc".utf8).write(to: fixture)
    let context = WorkspaceContext(
        root: directory,
        environment: ProcessInfo.processInfo.environment)

    try SHA256Verifier.verify(
        fixture,
        expectedDigest:
            "ba7816bf8f01cfea414140de5dae2223"
                + "b00361a396177a9cb410ff61f20015ad",
        context: context)

    #expect(throws: WorkspaceFailure.self) {
        try SHA256Verifier.verify(
            fixture,
            expectedDigest: String(repeating: "0", count: 64),
            context: context)
    }
}
