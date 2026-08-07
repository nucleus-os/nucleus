import Foundation
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
            activePrefix: prefix,
            architecture: .arm64)
        #expect(payload.count == 6)
        #expect(
            payload.filter(\.executable).map(\.path).sorted()
                == ["bin/nucleus-session", "bin/nucleus-session-validate"])
        #expect(
            payload.map(\.path).contains(
                "share/nucleus/host-requirements.json"))
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
