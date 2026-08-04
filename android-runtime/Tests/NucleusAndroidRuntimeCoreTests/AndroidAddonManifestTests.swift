import Foundation
import NucleusAndroidRuntimeCore
import Testing

@Suite struct AndroidAddonManifestTests {
    private let nucleusIdentity = String(repeating: "a", count: 64)
    private let kernelIdentity = String(repeating: "b", count: 64)

    @Test func manifestRoundTripsAndCanonicalizesPayloadOrder() throws {
        let manifest = try AndroidAddonManifest(
            release: "Android 17.0.0 Release 1",
            buildNumber: "nucleus-android17-r1",
            architecture: .arm64,
            requiredNucleusBuildIdentity: nucleusIdentity,
            requiredKernelCapabilityIdentity: kernelIdentity,
            payload: [
                try AndroidAddonPayloadFile(
                    path: "images/vendor.img",
                    size: 2,
                    sha256: String(repeating: "d", count: 64)),
                try AndroidAddonPayloadFile(
                    path: "libexec/nucleus-android-runtime",
                    size: 1,
                    sha256: String(repeating: "c", count: 64),
                    executable: true),
            ])
        #expect(
            manifest.payload.map(\.path) == [
                "images/vendor.img", "libexec/nucleus-android-runtime",
            ])
        let encoded = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(AndroidAddonManifest.self, from: encoded) == manifest)
    }

    @Test func manifestRejectsTraversalDuplicatesAndMalformedDigests() throws {
        #expect(throws: AndroidAddonManifestFailure.self) {
            _ = try AndroidAddonPayloadFile(
                path: "../images/system.img",
                size: 1,
                sha256: String(repeating: "a", count: 64))
        }
        #expect(throws: AndroidAddonManifestFailure.self) {
            _ = try AndroidAddonPayloadFile(
                path: "images/system image.img",
                size: 1,
                sha256: String(repeating: "a", count: 64))
        }
        #expect(throws: AndroidAddonManifestFailure.self) {
            _ = try AndroidAddonPayloadFile(
                path: "images/system.img",
                size: 1,
                sha256: "ABC")
        }
        let file = try AndroidAddonPayloadFile(
            path: "images/system.img",
            size: 1,
            sha256: String(repeating: "c", count: 64))
        #expect(throws: AndroidAddonManifestFailure.self) {
            _ = try AndroidAddonManifest(
                release: "Android 17",
                buildNumber: "r1",
                architecture: .arm64,
                requiredNucleusBuildIdentity: nucleusIdentity,
                requiredKernelCapabilityIdentity: kernelIdentity,
                payload: [file, file])
        }
    }

    @Test func compatibilityIsAnExactInstalledProductBoundary() throws {
        let manifest = try AndroidAddonManifest(
            release: "Android 17",
            buildNumber: "r1",
            architecture: .arm64,
            requiredNucleusBuildIdentity: nucleusIdentity,
            requiredKernelCapabilityIdentity: kernelIdentity,
            payload: [
                try AndroidAddonPayloadFile(
                    path: "images/system.img",
                    size: 1,
                    sha256: String(repeating: "c", count: 64))
            ])
        try manifest.validateCompatibility(
            AndroidAddonCompatibility(
                nucleusBuildIdentity: nucleusIdentity,
                kernelCapabilityIdentity: kernelIdentity,
                architecture: .arm64))
        #expect(throws: AndroidAddonManifestFailure.self) {
            try manifest.validateCompatibility(
                AndroidAddonCompatibility(
                    nucleusBuildIdentity: String(repeating: "d", count: 64),
                    kernelCapabilityIdentity: kernelIdentity,
                    architecture: .arm64))
        }
    }

    @Test func storeSeparatesImmutableContentFromPersistentState() throws {
        let layout = try AndroidAddonStoreLayout(
            root: URL(fileURLWithPath: "/opt/nucleus/addons/android"),
            persistentStateRoot: URL(fileURLWithPath: "/var/lib/nucleus/android"))
        #expect(layout.active.path == "/opt/nucleus/addons/android/current")
        #expect(layout.persistentStateRoot.path == "/var/lib/nucleus/android")
        #expect(
            layout.activeCapabilityManifest.path
                == "/opt/nucleus/addons/android/session-capabilities/android.json")
    }

    @Test func storeRejectsNestedContentAndStateRoots() {
        #expect(throws: (any Error).self) {
            _ = try AndroidAddonStoreLayout(
                root: URL(fileURLWithPath: "/var/lib/nucleus"),
                persistentStateRoot: URL(
                    fileURLWithPath: "/var/lib/nucleus/android-state"))
        }
        #expect(throws: (any Error).self) {
            _ = try AndroidAddonStoreLayout(
                root: URL(fileURLWithPath: "/var/lib/nucleus/android/content"),
                persistentStateRoot: URL(fileURLWithPath: "/var/lib/nucleus/android"))
        }
    }
}
