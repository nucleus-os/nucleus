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

@Test func aospContainerInvocationHasTheRequiredIsolationBoundary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-aosp-container-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true)
    let imageID = root.appendingPathComponent("image-id")
    try Data(
        ("sha256:" + String(repeating: "a", count: 64) + "\n").utf8
    ).write(to: imageID)
    let path = { (name: String) in
        FilePath(
            root.appendingPathComponent(name).path)
    }
    let build = AOSPProductBuild(
        productSource: path("product"),
        source: path("source"),
        repoLauncher: path("repo"),
        sourceProvenance: path("source-provenance.json"),
        buildRoot: path("build"),
        ccacheDirectory: path("ccache"),
        containerImageID: FilePath(imageID.path),
        signingIdentity: path("keys"),
        product: "nucleus_x86_64",
        release: "cp2a",
        variant: "user",
        buildNumber: "nucleus",
        buildTimestamp: 1,
        buildJobs: 16,
        expectedPlatformSDK: 37,
        expectedVendorAPILevel: 202604,
        environment: [:])

    let execution = aospProductOCIExecution(
        build: build,
        writableMounts: [
            (path("output"), "/output"),
            (path("ccache"), "/src/out/nucleus/.ccache"),
        ],
        readOnlyMounts: [(path("source"), "/src")],
        command: ["/bin/true"],
        containerEnvironment: ["TZ": "UTC"])
    let executor = AppleContainerExecutor()
    let flags = appleContainerFlags(
        execution,
        name: try executor.containerName(for: execution),
        temporaryDirectory: nil)

    #expect(execution.executionPlatform == .linuxAMD64OCI)
    #expect(execution.artifactTarget == .androidX86_64(apiLevel: 37))
    #expect(execution.processFilesystemPolicy == .unmasked)
    #expect(flags.management.networks == [OCIBackendContract.appleOfflineNetwork])
    #expect(flags.management.capDrop == ["ALL"])
    #expect(flags.management.readOnly)
    #expect(flags.management.tmpFs.contains("/tmp"))
    #expect(flags.management.tmpFs.contains("/home/nucleus-build"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(path("source").string),target=/src,readonly"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(path("output").string),target=/output"))
    #expect(
        flags.management.mounts.contains(
            "type=bind,source=\(path("ccache").string),"
                + "target=/src/out/nucleus/.ccache"))
    #expect(
        !flags.process.env.contains(where: {
            $0.contains("SSH_AUTH_SOCK") || $0.contains("WAYLAND_DISPLAY")
        }))
}

@Test func aospSandboxDegradationIsFatal() throws {
    #expect(throws: (any Error).self) {
        try rejectAOSPSandboxDegradation(
            "Build sandboxing disabled due to nsjail error.",
            status: 0)
    }
    #expect(throws: (any Error).self) {
        try rejectAOSPSandboxDegradation("", status: 1)
    }
    try rejectAOSPSandboxDegradation("sandbox active", status: 0)
}

@Test func aospSandboxValidationRequiresBothNegativeBoundaries() throws {
    let valid = """
        NUCLEUS_NSJAIL_FILE_HIDDEN
        NUCLEUS_NSJAIL_NETWORK_ISOLATED
        NUCLEUS_NSJAIL_ISOLATION_OK
        """
    try validateAOSPSandboxIsolation(valid, status: 0)
    #expect(throws: (any Error).self) {
        try validateAOSPSandboxIsolation(
            "NUCLEUS_NSJAIL_FILE_HIDDEN",
            status: 0)
    }
    #expect(throws: (any Error).self) {
        try validateAOSPSandboxIsolation(valid, status: 1)
    }
}

@Test func aospBrokenSandboxBehaviorMustFailClosed() throws {
    try validateAOSPBrokenSandboxBehavior(
        "nsjail sandbox probe failed with exit status 1",
        status: 2)
    #expect(throws: (any Error).self) {
        try validateAOSPBrokenSandboxBehavior(
            "Build sandboxing disabled due to nsjail error.",
            status: 0)
    }
    #expect(throws: (any Error).self) {
        try validateAOSPBrokenSandboxBehavior(
            "TARGET_PRODUCT='nucleus_x86_64'",
            status: 0)
    }
}

@Test func aospContainerToolsUseThePinnedJDK() {
    let environment = aospProductContainerToolEnvironment()
    let javaHome = "/src/prebuilts/jdk/jdk21/linux-x86"
    #expect(environment["JAVA_HOME"] == javaHome)
    #expect(environment["ANDROID_JAVA_HOME"] == javaHome)
    #expect(environment["PATH"]?.hasPrefix("\(javaHome)/bin:") == true)
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

@Test func aospProductStagingPreservesUnchangedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-aosp-product-stage-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for name in ["unchanged", "changed"] {
        try Data(name.utf8).write(
            to: source.appendingPathComponent(name))
        try Data(name.utf8).write(
            to: destination.appendingPathComponent(name))
    }
    try Data("metadata".utf8).write(
        to: destination.appendingPathComponent(
            ".nucleus-product-stage.json"))
    let unchanged = destination.appendingPathComponent("unchanged")
    let originalInode = try #require(
        FileManager.default.attributesOfItem(atPath: unchanged.path)[
            .systemFileNumber
        ] as? NSNumber)

    try synchronizeAOSPProductTree(
        from: FilePath(source.path),
        to: FilePath(destination.path),
        preservingAtRoot: [".nucleus-product-stage.json"],
        files: ColliderRuntime().actionFileSystem())
    #expect(
        FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                ".nucleus-product-stage.json"
            ).path))
    #expect(
        try FileManager.default.attributesOfItem(atPath: unchanged.path)[
            .systemFileNumber
        ] as? NSNumber == originalInode)

    try Data("replacement".utf8).write(
        to: source.appendingPathComponent("changed"))
    try synchronizeAOSPProductTree(
        from: FilePath(source.path),
        to: FilePath(destination.path),
        preservingAtRoot: [".nucleus-product-stage.json"],
        files: ColliderRuntime().actionFileSystem())
    #expect(
        try FileManager.default.attributesOfItem(atPath: unchanged.path)[
            .systemFileNumber
        ] as? NSNumber == originalInode)
    #expect(
        try String(
            contentsOf: destination.appendingPathComponent("changed"),
            encoding: .utf8) == "replacement")
}
