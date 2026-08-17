import Foundation
import LinuxPackageContracts
import SystemPackage
import Testing

@testable import ShellColliderRecipe

@Test func hostIntegrationRendersAgainstAnyActivePrefix() throws {
    let sourceRoot = sessionPackageRoot()
    let source = try Dictionary(
        uniqueKeysWithValues: RuntimeHostIntegration.sourceFiles.map { name in
            (
                name,
                Array(
                    try Data(
                        contentsOf: URL(
                            fileURLWithPath: sourceRoot.appending(name).string)))
            )
        })
    let unitTemplate = try String(
        contentsOfFile: sourceRoot.appending("nucleus@.service").string,
        encoding: .utf8)
    let desktopTemplate = try String(
        contentsOfFile: sourceRoot.appending("nucleus-wayland.desktop").string,
        encoding: .utf8)

    for prefix in [FilePath("/opt/nucleus"), FilePath("/srv/nucleus/runtime/current")] {
        let unit = RuntimeHostIntegration.render(
            unitTemplate,
            activePrefix: prefix)
        let desktop = RuntimeHostIntegration.render(
            desktopTemplate,
            activePrefix: prefix)
        try RuntimeHostIntegration.validatePublishedTemplate(
            unit,
            activePrefix: prefix,
            name: "nucleus@.service")
        try RuntimeHostIntegration.validatePublishedTemplate(
            desktop,
            activePrefix: prefix,
            name: "nucleus-wayland.desktop")
        #expect(unit.contains("ExecStart=\(prefix.string)/bin/nucleus-session"))
        #expect(desktop.contains("Exec=\(prefix.string)/bin/nucleus-session"))
        #expect(desktop.contains("TryExec=\(prefix.string)/bin/NucleusCompositor"))

        let payload = try RuntimeHostIntegration.payload(
            source: source,
            architecture: .arm64)
        #expect(payload.count == 6)
        #expect(
            payload.filter(\.executable).map(\.path).sorted()
                == ["bin/nucleus-session", "bin/nucleus-session-validate"])
        #expect(
            payload.map(\.path).contains(
                "share/nucleus/host-requirements.json"))
        #expect(
            payload.map(\.path).contains(
                "share/nucleus/host-integration/systemd/nucleus@.service.in"))
        #expect(
            payload.map(\.path).contains(
                "share/nucleus/host-integration/wayland/nucleus.desktop.in"))
    }
}

@Test func hostRequirementsAreDistributionNeutralAndMatchTheABIContract() throws {
    let bytes = try RuntimeHostIntegration.requirementsJSON(architecture: .arm64)
    let requirements = try JSONDecoder().decode(
        RuntimeHostRequirements.self,
        from: Data(bytes))

    #expect(requirements.architecture == "arm64")
    #expect(requirements.minimumGlibcVersion == "2.38")
    #expect(requirements.serviceManager == "systemd")
    #expect(requirements.pamService == "nucleus")
    #expect(requirements.sessionBus == "private-dbus-run-session")
    #expect(requirements.requiredCapabilities.contains("seat.libseat"))
    #expect(requirements.requiredCapabilities.contains("vulkan.loader"))
    #expect(requirements.requiredExecutables == ["bash", "dbus-run-session"])
    #expect(requirements.hostLibraries.contains("libvulkan.so.1"))
    #expect(requirements.hostLibraries.contains("libpam.so.0"))
    #expect(requirements.hostLibraries.contains("ld-linux-aarch64.so.1"))
    #expect(!requirements.hostLibraries.contains("ld-linux-x86-64.so.2"))
    #expect(!String(decoding: bytes, as: UTF8.self).lowercased().contains("ubuntu"))
}

@Test func distributionAdaptersConsumeOneRuntimeArtifactWithoutBuildInputs() throws {
    let templates = try hostIntegrationTemplates()
    let digest = "sha256:" + String(repeating: "a", count: 64)

    let manifests = try LinuxDistributionPackageAdapter.all.map {
        try $0.manifest(
            architecture: .arm64,
            artifactDigest: digest,
            systemdUnitTemplate: templates.systemd,
            desktopEntryTemplate: templates.desktop,
            pamTemplate: templates.pam)
    }

    #expect(manifests.map(\.family) == [.debian, .rpm, .arch])
    #expect(Set(manifests.map(\.artifactDigest)) == [digest])
    #expect(
        Set(manifests.map(\.runtimeRoot))
            == [LinuxDistributionPackageAdapter.runtimeRoot])
    for manifest in manifests {
        #expect(!manifest.dependencies.contains { $0.contains("-dev") })
        #expect(!manifest.dependencies.contains("clang"))
        #expect(!manifest.dependencies.contains("cmake"))
        #expect(!manifest.dependencies.contains("ninja"))
        #expect(
            Set(manifest.capabilityPackages.keys)
                == Set(RuntimeHostRequirements.linuxCapabilities))
        #expect(
            manifest.installations.map(\.destination).sorted()
                == manifest.removals)
        #expect(manifest.seatPolicy == "systemd-logind")
        #expect(
            manifest.installations.contains {
                $0.kind == .tree && $0.destination == manifest.runtimeGeneration
            })
        #expect(
            manifest.installations.contains {
                $0.kind == .symbolicLink
                    && $0.destination == manifest.runtimeRoot
                    && $0.target == manifest.runtimeGeneration
            })
        let pamPolicy = try #require(
            manifest.installations.first {
                $0.destination == "/etc/pam.d/nucleus"
            }?.contents)
        #expect(!pamPolicy.contains("@authentication-stack@"))
        #expect(!pamPolicy.contains("@account-stack@"))
        #expect(pamPolicy.contains("auth include "))
        #expect(pamPolicy.contains("account include "))
    }
}

@Test func distributionAdaptersUseNativeArchitectureNames() throws {
    let templates = try hostIntegrationTemplates()
    let digest = "sha256:" + String(repeating: "b", count: 64)

    let architectures = try LinuxDistributionPackageAdapter.all.map { adapter in
        (
            try adapter.manifest(
                architecture: .arm64,
                artifactDigest: digest,
                systemdUnitTemplate: templates.systemd,
                desktopEntryTemplate: templates.desktop,
                pamTemplate: templates.pam
            ).architecture,
            try adapter.manifest(
                architecture: .x86_64,
                artifactDigest: digest,
                systemdUnitTemplate: templates.systemd,
                desktopEntryTemplate: templates.desktop,
                pamTemplate: templates.pam
            ).architecture
        )
    }
    #expect(architectures.map(\.0) == ["arm64", "aarch64", "aarch64"])
    #expect(architectures.map(\.1) == ["amd64", "x86_64", "x86_64"])
}

@Test func distributionPackageManifestsAreDeterministicAndDecodable() throws {
    let templates = try hostIntegrationTemplates()
    let digest = "sha256:" + String(repeating: "c", count: 64)

    let first = try LinuxDistributionPackaging.encodedManifests(
        architecture: .x86_64,
        artifactDigest: digest,
        systemdUnitTemplate: templates.systemd,
        desktopEntryTemplate: templates.desktop,
        pamTemplate: templates.pam)
    let second = try LinuxDistributionPackaging.encodedManifests(
        architecture: .x86_64,
        artifactDigest: digest,
        systemdUnitTemplate: templates.systemd,
        desktopEntryTemplate: templates.desktop,
        pamTemplate: templates.pam)

    #expect(first.map(\.family) == [.debian, .rpm, .arch])
    #expect(first.map(\.bytes) == second.map(\.bytes))
    for encoded in first {
        let manifest = try JSONDecoder().decode(
            LinuxDistributionPackageManifest.self,
            from: Data(encoded.bytes))
        #expect(manifest.family == encoded.family)
        #expect(manifest.artifactDigest == digest)
    }
}

@Test func distributionPackageRootsInstallAndRemoveOnlyDeclaredFiles() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true)
    let runtime = temporary.appendingPathComponent("runtime", isDirectory: true)
    let packageRoot = temporary.appendingPathComponent("package", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(
        at: runtime.appendingPathComponent("bin", isDirectory: true),
        withIntermediateDirectories: true)
    try Data("runtime\n".utf8).write(
        to: runtime.appendingPathComponent("bin/NucleusCompositor"))
    let templates = try hostIntegrationTemplates()
    let manifest = try LinuxDistributionPackageAdapter(family: .debian).manifest(
        architecture: .arm64,
        artifactDigest: "sha256:" + String(repeating: "d", count: 64),
        systemdUnitTemplate: templates.systemd,
        desktopEntryTemplate: templates.desktop,
        pamTemplate: templates.pam)

    try LinuxDistributionPackaging.stagePackageRoot(
        manifest: manifest,
        runtimeArtifact: runtime,
        packageRoot: packageRoot)

    for path in manifest.removals {
        let url = packageRoot.appendingPathComponent(String(path.dropFirst()))
        #expect(
            (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil)
    }
    let pam = try String(
        contentsOf: packageRoot.appendingPathComponent("etc/pam.d/nucleus"),
        encoding: .utf8)
    #expect(pam.contains("auth include common-auth"))
    #expect(pam.contains("account include common-account"))
    let unit = try String(
        contentsOf: packageRoot.appendingPathComponent(
            "usr/lib/systemd/user/nucleus@.service"),
        encoding: .utf8)
    #expect(unit.contains("ExecStart=/opt/nucleus/current/bin/nucleus-session"))

    try LinuxDistributionPackaging.removePackageFiles(
        manifest: manifest,
        packageRoot: packageRoot)
    for path in manifest.removals {
        let url = packageRoot.appendingPathComponent(String(path.dropFirst()))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Test func pamTemplateRequiresDistributionOwnedStacksWithoutLoginFallback() throws {
    let template = try String(
        contentsOfFile: sessionPackageRoot().appending("nucleus.pam.in").string,
        encoding: .utf8)
    try RuntimeHostIntegration.validatePAMTemplate(template)
}

private func sessionPackageRoot() -> FilePath {
    FilePath(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("compositor/packages/session")
            .path)
}

private func hostIntegrationTemplates() throws -> (
    systemd: String,
    desktop: String,
    pam: String
) {
    let root = sessionPackageRoot()
    return (
        try String(
            contentsOfFile: root.appending("nucleus@.service").string,
            encoding: .utf8),
        try String(
            contentsOfFile: root.appending("nucleus-wayland.desktop").string,
            encoding: .utf8),
        try String(
            contentsOfFile: root.appending("nucleus.pam.in").string,
            encoding: .utf8)
    )
}
