import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import AndroidRuntimeColliderRecipe
@testable import ColliderRuntime

@Test func aospProductDefinitionDigestIncludesEveryOverlayCanonically() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-aosp-product-hash-\(UUID().uuidString)")
    let product = directory.appendingPathComponent("product")
    let firstOverlay = directory.appendingPathComponent("first-overlay")
    let secondOverlay = directory.appendingPathComponent("second-overlay")
    for path in [product, firstOverlay, secondOverlay] {
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("product".utf8).write(
        to: product.appendingPathComponent("device.mk"))
    try Data("first".utf8).write(
        to: firstOverlay.appendingPathComponent("transport.c"))
    try Data("second".utf8).write(
        to: secondOverlay.appendingPathComponent("policy.c"))

    let overlays = [
        AOSPProductSourceOverlay(
            source: FilePath(firstOverlay.path),
            relativeDestination: "native/transport"),
        AOSPProductSourceOverlay(
            source: FilePath(secondOverlay.path),
            relativeDestination: "native/policy"),
    ]
    let files = ColliderRuntime().actionFileSystem()
    let initial = try aospProductDefinitionDigest(
        productSource: FilePath(product.path),
        sourceOverlays: overlays,
        files: files)
    #expect(
        try aospProductDefinitionDigest(
            productSource: FilePath(product.path),
            sourceOverlays: Array(overlays.reversed()),
            files: files) == initial)

    try Data("changed".utf8).write(
        to: firstOverlay.appendingPathComponent("transport.c"))
    #expect(
        try aospProductDefinitionDigest(
            productSource: FilePath(product.path),
            sourceOverlays: overlays,
            files: files) != initial)
    #expect(
        try aospProductDefinitionDigest(
            productSource: FilePath(product.path),
            sourceOverlays: [],
            files: files) != initial)
}

@Test func aospBuildStatusMustSucceed() throws {
    try requireAOSPBuildSuccess(0)
    #expect(throws: (any Error).self) {
        try requireAOSPBuildSuccess(1)
    }
}

@Test func aospContainerToolsUseThePinnedJDK() {
    let environment = aospProductContainerToolEnvironment()
    let javaHome = "/src/prebuilts/jdk/jdk21/linux-x86"
    #expect(environment["JAVA_HOME"] == javaHome)
    #expect(environment["ANDROID_JAVA_HOME"] == javaHome)
    #expect(environment["PATH"]?.hasPrefix("\(javaHome)/bin:") == true)
    #expect(environment["SOONG_OUTER_SANDBOX"] == "1")
    #expect(environment["SOONG_BOOTSTRAP_PREBUILT_TAG"] == "linux-x86")
}

@Test func aospReleaseSigningMetadataUsesStableContainerKeyPaths() {
    let metadata = """
        avb_vbmeta_key_path=/keys/releasekey.pem
        avb_vbmeta_system_key_path=/keys/releasekey.pem
        default_system_dev_certificate=/keys/releasekey
        """
    #expect(aospReleaseSigningMetadataUsesContainerKeys(metadata))
    #expect(
        !aospReleaseSigningMetadataUsesContainerKeys(
            metadata.replacingOccurrences(
                of: "/keys/releasekey",
                with: "/home/user/signing/releasekey")))
}

@Test func aospFontContractResolvesEveryConfiguredFont() throws {
    let configurations = [
        "SYSTEM/etc/fonts.xml": """
        <familyset>
          <family name="sans-serif">
            <font weight="400">Roboto-Regular.ttf</font>
          </family>
          <family>
            <font>NotoColorEmojiLegacy.ttf</font>
          </family>
        </familyset>
        """,
        "SYSTEM/etc/font_fallback.xml": """
        <familyset>
          <family>
            <font>NotoColorEmoji.ttf</font>
            <font>/product/fonts/DisplaySerif.ttf</font>
          </family>
        </familyset>
        """,
    ]
    try validateAOSPFontContract(
        archiveEntries: Array(configurations.keys) + [
            "SYSTEM/fonts/Roboto-Regular.ttf",
            "SYSTEM/fonts/NotoColorEmojiLegacy.ttf",
            "SYSTEM/fonts/NotoColorEmoji.ttf",
            "PRODUCT/fonts/DisplaySerif.ttf",
        ],
        configurations: configurations)
}

@Test func aospFontContractRejectsMissingConfigurationAndAssets() {
    let fontsXML = """
        <familyset>
          <family name="sans-serif">
            <font>Roboto-Regular.ttf</font>
          </family>
        </familyset>
        """
    #expect(throws: (any Error).self) {
        try validateAOSPFontContract(
            archiveEntries: [
                "SYSTEM/etc/fonts.xml",
                "SYSTEM/fonts/Roboto-Regular.ttf",
            ],
            configurations: ["SYSTEM/etc/fonts.xml": fontsXML])
    }

    #expect(throws: (any Error).self) {
        try validateAOSPFontContract(
            archiveEntries: [
                "SYSTEM/etc/fonts.xml",
                "SYSTEM/etc/font_fallback.xml",
                "SYSTEM/fonts/Roboto-Regular.ttf",
            ],
            configurations: [
                "SYSTEM/etc/fonts.xml": fontsXML,
                "SYSTEM/etc/font_fallback.xml": """
                <familyset>
                  <family><font>MissingFallback.ttf</font></family>
                </familyset>
                """,
            ])
    }
}
