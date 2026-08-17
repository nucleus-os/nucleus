import Foundation
import Testing

@testable import NucleusAndroidRuntimeCore

@Suite struct AndroidPackageManifestTests {
    @Test func manifestRoundTripsPackagePayloadIdentity() throws {
        let manifest = try AndroidPackageManifest(
            release: "Android 17",
            buildNumber: "build-1",
            architecture: .x86_64,
            payload: [
                try AndroidPackagePayloadFile(
                    path: "images/system.img",
                    size: 4,
                    sha256: String(repeating: "a", count: 64))
            ])
        let encoded = try JSONEncoder().encode(manifest)
        #expect(
            try JSONDecoder().decode(AndroidPackageManifest.self, from: encoded)
                == manifest)
    }

    @Test func payloadRejectsTraversalAndInvalidDigest() {
        #expect(throws: AndroidPackageManifestFailure.self) {
            _ = try AndroidPackagePayloadFile(
                path: "../system.img",
                size: 4,
                sha256: String(repeating: "a", count: 64))
        }
        #expect(throws: AndroidPackageManifestFailure.self) {
            _ = try AndroidPackagePayloadFile(
                path: "images/system.img",
                size: 4,
                sha256: "not-a-digest")
        }
    }
}
