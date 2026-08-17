import ColliderCore
import Foundation
import LinuxPackageContracts
import SystemPackage

/// Translates the common runtime contract into package-manager vocabulary and
/// standard host-integration paths. It never builds or alters the runtime.
package struct LinuxDistributionPackageAdapter: Sendable {
    package static let runtimeRoot = LinuxDistributionFamily.runtimeRoot

    package let family: LinuxDistributionFamily

    package init(family: LinuxDistributionFamily) {
        self.family = family
    }

    package static var all: [Self] {
        LinuxDistributionFamily.allCases.map(Self.init(family:))
    }

    package var capabilityPackages: [String: [String]] {
        switch family {
        case .debian:
            [
                "dbus.session": ["dbus-daemon"],
                "drm.kms": ["libdrm2", "libgbm1"],
                "input.libinput": ["libinput10"],
                "pam.authentication": ["libpam0g"],
                "seat.libseat": ["libseat1", "systemd"],
                "udev.devices": ["libudev1", "systemd"],
                "vulkan.loader": ["libvulkan1"],
                "wayland": [
                    "libwayland-client0", "libwayland-server0", "libxkbcommon0",
                ],
                "xwayland": ["xwayland"],
            ]
        case .rpm:
            [
                "dbus.session": ["dbus-daemon"],
                "drm.kms": ["libdrm", "mesa-libgbm"],
                "input.libinput": ["libinput"],
                "pam.authentication": ["pam"],
                "seat.libseat": ["libseat", "systemd"],
                "udev.devices": ["systemd"],
                "vulkan.loader": ["vulkan-loader"],
                "wayland": ["wayland", "libxkbcommon"],
                "xwayland": ["xorg-x11-server-Xwayland"],
            ]
        case .arch:
            [
                "dbus.session": ["dbus"],
                "drm.kms": ["libdrm", "mesa"],
                "input.libinput": ["libinput"],
                "pam.authentication": ["pam"],
                "seat.libseat": ["seatd", "systemd"],
                "udev.devices": ["systemd"],
                "vulkan.loader": ["vulkan-icd-loader"],
                "wayland": ["wayland", "libxkbcommon"],
                "xwayland": ["xorg-xwayland"],
            ]
        }
    }

    package var dependencies: [String] {
        Array(Set(capabilityPackages.values.joined()).union(["bash"]))
            .sorted()
    }

    package var pamStacks: (authentication: String, account: String) {
        switch family {
        case .debian:
            ("common-auth", "common-account")
        case .rpm, .arch:
            ("system-auth", "system-auth")
        }
    }

    package func installations(
        runtimeGeneration: String,
        systemdUnit: String,
        desktopEntry: String,
        pamPolicy: String
    ) -> [LinuxPackageInstallation] {
        [
            LinuxPackageInstallation(
                source: ".",
                destination: runtimeGeneration,
                kind: .tree,
                target: nil,
                contents: nil),
            .symbolicLink(
                Self.runtimeRoot,
                target: runtimeGeneration),
            .file(
                "/usr/lib/systemd/user/nucleus@.service",
                contents: systemdUnit),
            .file(
                "/usr/share/wayland-sessions/nucleus.desktop",
                contents: desktopEntry),
            .file(
                "/etc/pam.d/nucleus",
                contents: pamPolicy),
        ]
    }

    package func removals(
        runtimeGeneration: String,
        systemdUnit: String,
        desktopEntry: String,
        pamPolicy: String
    ) -> [String] {
        installations(
            runtimeGeneration: runtimeGeneration,
            systemdUnit: systemdUnit,
            desktopEntry: desktopEntry,
            pamPolicy: pamPolicy
        )
        .map(\.destination).sorted()
    }

    package func renderPAMPolicy(_ template: String) throws -> String {
        try RuntimeHostIntegration.validatePAMTemplate(template)
        return
            template
            .replacing(
                "@authentication-stack@",
                with: pamStacks.authentication
            )
            .replacing("@account-stack@", with: pamStacks.account)
    }

    package func manifest(
        architecture: PlatformArchitecture,
        artifactDigest: String,
        systemdUnitTemplate: String,
        desktopEntryTemplate: String,
        pamTemplate: String
    ) throws -> LinuxDistributionPackageManifest {
        guard artifactDigest.hasPrefix("sha256:"), artifactDigest.count == 71 else {
            throw RuntimeHostIntegrationFailure(
                "Linux package artifact digest must be a complete SHA-256 digest")
        }
        let identity = String(artifactDigest.dropFirst("sha256:".count).prefix(24))
        guard identity.allSatisfy(\.isHexDigit) else {
            throw RuntimeHostIntegrationFailure(
                "Linux package artifact digest must contain only hexadecimal digits")
        }
        let runtimeGeneration = "/opt/nucleus/generations/\(identity)"
        let activePrefix = FilePath(Self.runtimeRoot)
        let systemdUnit = RuntimeHostIntegration.render(
            systemdUnitTemplate,
            activePrefix: activePrefix)
        try RuntimeHostIntegration.validatePublishedTemplate(
            systemdUnit,
            activePrefix: activePrefix,
            name: "nucleus@.service")
        let desktopEntry = RuntimeHostIntegration.render(
            desktopEntryTemplate,
            activePrefix: activePrefix)
        try RuntimeHostIntegration.validatePublishedTemplate(
            desktopEntry,
            activePrefix: activePrefix,
            name: "nucleus.desktop")
        let pamPolicy = try renderPAMPolicy(pamTemplate)
        return LinuxDistributionPackageManifest(
            family: family,
            architecture: packageArchitecture(architecture),
            artifactDigest: artifactDigest,
            runtimeRoot: Self.runtimeRoot,
            runtimeGeneration: runtimeGeneration,
            seatPolicy: "systemd-logind",
            capabilityPackages: capabilityPackages,
            dependencies: dependencies,
            installations: installations(
                runtimeGeneration: runtimeGeneration,
                systemdUnit: systemdUnit,
                desktopEntry: desktopEntry,
                pamPolicy: pamPolicy),
            removals: removals(
                runtimeGeneration: runtimeGeneration,
                systemdUnit: systemdUnit,
                desktopEntry: desktopEntry,
                pamPolicy: pamPolicy))
    }

    package func packageArchitecture(_ architecture: PlatformArchitecture) -> String {
        family.packageArchitecture(architecture)
    }
}

package enum LinuxDistributionPackaging {
    package static func encodedManifests(
        architecture: PlatformArchitecture,
        artifactDigest: String,
        systemdUnitTemplate: String,
        desktopEntryTemplate: String,
        pamTemplate: String
    ) throws -> [(family: LinuxDistributionFamily, bytes: [UInt8])] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try LinuxDistributionPackageAdapter.all.map { adapter in
            var bytes = Array(
                try encoder.encode(
                    adapter.manifest(
                        architecture: architecture,
                        artifactDigest: artifactDigest,
                        systemdUnitTemplate: systemdUnitTemplate,
                        desktopEntryTemplate: desktopEntryTemplate,
                        pamTemplate: pamTemplate)))
            bytes.append(0x0a)
            return (adapter.family, bytes)
        }
    }

    package static func stagePackageRoot(
        manifest: LinuxDistributionPackageManifest,
        runtimeArtifact: URL,
        packageRoot: URL,
        files: FileManager = .default
    ) throws {
        try files.createDirectory(
            at: packageRoot,
            withIntermediateDirectories: true)
        for installation in manifest.installations {
            let destination = try packageURL(
                installation.destination,
                beneath: packageRoot)
            try files.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if (try? files.attributesOfItem(atPath: destination.path)) != nil {
                try files.removeItem(at: destination)
            }
            switch installation.kind {
            case .tree:
                guard installation.source == "." else {
                    throw RuntimeHostIntegrationFailure(
                        "runtime tree installation must consume the artifact root")
                }
                try files.copyItem(at: runtimeArtifact, to: destination)
            case .file:
                guard let contents = installation.contents else {
                    throw RuntimeHostIntegrationFailure(
                        "package file has no contents: \(installation.destination)")
                }
                try Data(contents.utf8).write(
                    to: destination,
                    options: .atomic)
            case .symbolicLink:
                guard let target = installation.target else {
                    throw RuntimeHostIntegrationFailure(
                        "package symbolic link has no target: \(installation.destination)")
                }
                try files.createSymbolicLink(
                    atPath: destination.path,
                    withDestinationPath: target)
            }
        }
    }

    package static func removePackageFiles(
        manifest: LinuxDistributionPackageManifest,
        packageRoot: URL,
        files: FileManager = .default
    ) throws {
        for path in manifest.removals.sorted(by: { $0.count > $1.count }) {
            let destination = try packageURL(path, beneath: packageRoot)
            if (try? files.attributesOfItem(atPath: destination.path)) != nil {
                try files.removeItem(at: destination)
            }
        }
    }

    private static func packageURL(
        _ absolutePath: String,
        beneath root: URL
    ) throws -> URL {
        guard absolutePath.hasPrefix("/"), !absolutePath.split(separator: "/").contains("..")
        else {
            throw RuntimeHostIntegrationFailure(
                "package destination must be a normalized absolute path: \(absolutePath)")
        }
        return root.appendingPathComponent(String(absolutePath.dropFirst()))
    }
}
