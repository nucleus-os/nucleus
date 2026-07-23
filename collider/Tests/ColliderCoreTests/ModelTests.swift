import Testing
@testable import ColliderCore
import Foundation

@Test func artifactDigestHasAnAlgorithmLabel() {
    #expect(ArtifactDigest(bytes: [0, 1, 254, 255]).description
        == "sha256:0001feff")
}

@Test func artifactDigestParsesOnlyCompleteLowercaseSHA256() {
    let value = String(repeating: "0a", count: 32)
    #expect(ArtifactDigest(sha256Hex: value)?.description == "sha256:" + value)
    #expect(ArtifactDigest(sha256Hex: String(repeating: "0A", count: 32)) == nil)
    #expect(ArtifactDigest(sha256Hex: "00") == nil)
}

@Test func downloadSpecificationsRejectUnboundedOrUnverifiedInputs() throws {
    let digest = ArtifactDigest(bytes: [UInt8](repeating: 0, count: 32))
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "http://example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: digest,
            maximumResponseSize: 1,
            acceptedMediaTypes: ["application/octet-stream"])
    }
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "https://user:secret@example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: digest,
            maximumResponseSize: 1,
            acceptedMediaTypes: ["application/octet-stream"])
    }
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "https://example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: ArtifactDigest(bytes: [0]),
            maximumResponseSize: 1,
            acceptedMediaTypes: ["application/octet-stream"])
    }
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "https://example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: digest,
            maximumResponseSize: 0,
            acceptedMediaTypes: ["application/octet-stream"])
    }
}
