import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import AndroidRuntimeColliderRecipe
@testable import ColliderRuntime

private struct AOSPValidationFixtureProcessResult {
    let status: Int32
    let output: String
}

private func runAOSPValidationFixturePython(
    arguments: [String],
    environment: [String: String]
) throws -> AOSPValidationFixtureProcessResult {
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3"] + arguments
    process.environment = ProcessInfo.processInfo.environment.merging(
        environment,
        uniquingKeysWith: { _, fixture in fixture })
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return AOSPValidationFixtureProcessResult(
        status: process.terminationStatus,
        output: String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self))
}

@Test func aospPackageValidationBatchesCertificatesAndAPEXPayloads() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-aosp-package-validation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true)

    let program = root.appendingPathComponent("validate-packages.py")
    try Data(aospPackageValidationProgram.utf8).write(to: program)
    let apksigner = root.appendingPathComponent("apksigner")
    try Data(
        """
        #!/bin/sh
        printf '%s\\n' 'Signer #1 certificate SHA-256 digest: abc123'
        """.utf8
    ).write(to: apksigner)
    let avbtool = root.appendingPathComponent("avbtool")
    try Data(
        """
        #!/bin/sh
        printf 'verified\\n' >> "$AOSP_VALIDATION_MARKER"
        """.utf8
    ).write(to: avbtool)
    for tool in [apksigner, avbtool] {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }

    let archive = root.appendingPathComponent("target-files.zip")
    let archiveCreation = try runAOSPValidationFixturePython(
        arguments: [
            "-c",
            """
            import pathlib, sys, zipfile
            root = pathlib.Path(sys.argv[1])
            apex = root / "Test.apex"
            with zipfile.ZipFile(apex, "w") as output:
                output.writestr("apex_payload.img", b"payload")
            with zipfile.ZipFile(root / "target-files.zip", "w") as output:
                output.writestr("SYSTEM/app/Test.apk", b"apk")
                output.write(apex, "SYSTEM/apex/Test.apex")
            """,
            root.path,
        ],
        environment: [:])
    #expect(archiveCreation.status == 0)

    let scratch = root.appendingPathComponent("scratch")
    let marker = root.appendingPathComponent("avbtool-invocations")
    try FileManager.default.createDirectory(
        at: scratch, withIntermediateDirectories: true)
    let result = try runAOSPValidationFixturePython(
        arguments: [
            program.path,
            "--archive", archive.path,
            "--scratch", scratch.path,
            "--apksigner", apksigner.path,
            "--avbtool", avbtool.path,
            "--release-key", root.appendingPathComponent("release.pem").path,
            "--certificate-sha256", "abc123",
            "--minimum-sdk", "37",
            "--workers", "4",
        ],
        environment: ["AOSP_VALIDATION_MARKER": marker.path])
    #expect(result.status == 0, Comment(rawValue: result.output))
    #expect(result.output.contains("verified 2 packages (1 APEX payload)"))
    #expect(
        (try? String(contentsOf: marker, encoding: .utf8)) == "verified\n")

    let rejected = try runAOSPValidationFixturePython(
        arguments: [
            program.path,
            "--archive", archive.path,
            "--scratch", root.appendingPathComponent("rejected").path,
            "--apksigner", apksigner.path,
            "--avbtool", avbtool.path,
            "--release-key", root.appendingPathComponent("release.pem").path,
            "--certificate-sha256", "deadbeef",
            "--minimum-sdk", "37",
            "--workers", "4",
        ],
        environment: ["AOSP_VALIDATION_MARKER": marker.path])
    #expect(rejected.status != 0)
    #expect(rejected.output.contains("does not carry exactly"))
}

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

@Test func aospFontContractUsesAuthoritativeFallbackConfiguration() throws {
    let configurations = [
        "SYSTEM/etc/fonts.xml": """
        <familyset>
          <family name="sans-serif">
            <font weight="400">Roboto-Regular.ttf
              <axis tag="wght" stylevalue="400"/>
            </font>
          </family>
          <family ignore="true">
            <font>NotoColorEmojiLegacy.ttf</font>
          </family>
          <family><font>NotoSerifKhmer-Regular.otf</font></family>
        </familyset>
        """,
        "SYSTEM/etc/font_fallback.xml": """
        <familyset>
          <family>
            <font>NotoColorEmoji.ttf</font>
            <font>/product/fonts/DisplaySerif.ttf</font>
          </family>
          <family ignore="true"><font>IgnoredMissing.ttf</font></family>
        </familyset>
        """,
    ]
    try validateAOSPFontContract(
        archiveEntries: Array(configurations.keys) + [
            "SYSTEM/fonts/Roboto-Regular.ttf",
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

    #expect(throws: (any Error).self) {
        try validateAOSPFontContract(
            archiveEntries: [
                "SYSTEM/etc/fonts.xml",
                "SYSTEM/etc/font_fallback.xml",
                "SYSTEM/fonts/Roboto-Regular.ttf",
                "PRODUCT/fonts/WrongRoot.ttf",
            ],
            configurations: [
                "SYSTEM/etc/fonts.xml": fontsXML,
                "SYSTEM/etc/font_fallback.xml": """
                <familyset>
                  <family><font>WrongRoot.ttf</font></family>
                </familyset>
                """,
            ])
    }
}
