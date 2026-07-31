import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

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

    let execution = aospOCIExecution(
        build: build,
        writableMounts: [
            (path("output"), "/output"),
            (path("ccache"), "/src/out/nucleus/.ccache"),
        ],
        readOnlyMounts: [(path("source"), "/src")],
        environment: ["TZ": "UTC"],
        command: ["/bin/true"])
    let command = try PodmanExecutor().runCommand(
        execution,
        imageID: "sha256:" + String(repeating: "a", count: 64),
        temporaryDirectory: nil)
    let arguments = command.arguments

    #expect(execution.executionPlatform == .linuxAMD64OCI)
    #expect(execution.artifactTarget == .androidX86_64(apiLevel: 37))
    #expect(execution.processFilesystemPolicy == .unmasked)
    #expect(arguments.contains("--network=none"))
    #expect(arguments.contains("--cap-drop=all"))
    #expect(arguments.contains("--security-opt=no-new-privileges"))
    #expect(arguments.contains("--security-opt=unmask=/proc/*"))
    #expect(arguments.contains("--hostname=android-build"))
    #expect(arguments.contains("--read-only"))
    #expect(arguments.contains("--tmpfs=/tmp:rw,nosuid,nodev,size=8g"))
    #expect(
        arguments.contains(
            "--tmpfs=/home/nucleus-build:rw,nosuid,nodev,noexec,size=1g"))
    #expect(!arguments.contains("--privileged"))
    #expect(!arguments.contains("--security-opt=seccomp=unconfined"))
    #expect(!arguments.contains("--security-opt=unmask=ALL"))
    #expect(
        arguments.contains(
            "type=bind,src=\(path("source").string),target=/src,ro=true"))
    #expect(
        arguments.contains(
            "type=bind,src=\(path("output").string),target=/output,rw=true"))
    #expect(
        arguments.contains(
            "type=bind,src=\(path("ccache").string),"
                + "target=/src/out/nucleus/.ccache,rw=true"))
    #expect(
        !arguments.contains(where: {
            $0.contains("SSH_AUTH_SOCK") || $0.contains("WAYLAND_DISPLAY")
        }))
}

@Test func aospSandboxDegradationIsFatal() throws {
    #expect(throws: RuntimeFailure.self) {
        try rejectAOSPSandboxDegradation(
            "Build sandboxing disabled due to nsjail error.",
            status: 0)
    }
    #expect(throws: RuntimeFailure.self) {
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
    #expect(throws: RuntimeFailure.self) {
        try validateAOSPSandboxIsolation(
            "NUCLEUS_NSJAIL_FILE_HIDDEN",
            status: 0)
    }
    #expect(throws: RuntimeFailure.self) {
        try validateAOSPSandboxIsolation(valid, status: 1)
    }
}

@Test func aospBrokenSandboxBehaviorMustFailClosed() throws {
    try validateAOSPBrokenSandboxBehavior(
        "nsjail sandbox probe failed with exit status 1",
        status: 2)
    #expect(throws: RuntimeFailure.self) {
        try validateAOSPBrokenSandboxBehavior(
            "Build sandboxing disabled due to nsjail error.",
            status: 0)
    }
    #expect(throws: RuntimeFailure.self) {
        try validateAOSPBrokenSandboxBehavior(
            "TARGET_PRODUCT='nucleus_x86_64'",
            status: 0)
    }
}

@Test func aospContainerToolsUseThePinnedJDK() {
    let environment = aospContainerToolEnvironment()
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
    #expect(throws: RuntimeFailure.self) {
        try validateAOSPFontContract(
            archiveEntries: [
                "SYSTEM/etc/fonts.xml",
                "SYSTEM/fonts/Roboto-Regular.ttf",
            ],
            configurations: ["SYSTEM/etc/fonts.xml": fontsXML])
    }

    #expect(throws: RuntimeFailure.self) {
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
        preservingAtRoot: [".nucleus-product-stage.json"])
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
        preservingAtRoot: [".nucleus-product-stage.json"])
    #expect(
        try FileManager.default.attributesOfItem(atPath: unchanged.path)[
            .systemFileNumber
        ] as? NSNumber == originalInode)
    #expect(
        try String(
            contentsOf: destination.appendingPathComponent("changed"),
            encoding: .utf8) == "replacement")
}
