import ColliderCore
import Foundation
import SystemPackage

package enum LinuxNativePackageName: String, CaseIterable, Codable, Hashable, Sendable {
    case runtime = "nucleus-runtime"
    case session = "nucleus-session"
    case browser = "nucleus-browser"
    case androidAddon = "nucleus-android-addon"
    case developmentHost = "nucleus-development-host"
    case complete = "nucleus"

    package static let controlOnly: [LinuxNativePackageName] = [
        .session, .developmentHost, .complete,
    ]

    package var isControlOnly: Bool {
        Self.controlOnly.contains(self)
    }
}

package enum LinuxNativePackagePathKind: String, Codable, Sendable {
    case file
    case symbolicLink = "symbolic-link"
    case tree
}

package struct LinuxNativePackageOwnedPath: Codable, Equatable, Sendable {
    package let path: String
    package let kind: LinuxNativePackagePathKind
    package let permissions: UInt16?
    package let symbolicLinkTarget: String?
    package let configurationFile: Bool

    package init(
        path: String,
        kind: LinuxNativePackagePathKind,
        permissions: UInt16? = nil,
        symbolicLinkTarget: String? = nil,
        configurationFile: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.permissions = permissions
        self.symbolicLinkTarget = symbolicLinkTarget
        self.configurationFile = configurationFile
    }
}

package struct LinuxNativePackageRelationship: Codable, Equatable, Sendable {
    package enum Requirement: String, Codable, Sendable {
        case exactCohort = "exact-cohort"
        case runtimeCapability = "runtime-capability"
    }

    package let package: String
    package let requirement: Requirement
    package let version: String?

    package init(
        package: String,
        requirement: Requirement,
        version: String? = nil
    ) {
        self.package = package
        self.requirement = requirement
        self.version = version
    }
}

package struct LinuxNativePackageLifecycle: Codable, Equatable, Sendable {
    package let afterInstall: [String]
    package let afterRemove: [String]

    package init(afterInstall: [String] = [], afterRemove: [String] = []) {
        self.afterInstall = afterInstall
        self.afterRemove = afterRemove
    }
}

package struct LinuxNativePackageManifest: Codable, Equatable, Sendable {
    package let family: LinuxDistributionFamily
    package let name: LinuxNativePackageName
    package let version: String
    package let architecture: String
    package let summary: String
    package let relationships: [LinuxNativePackageRelationship]
    package let conflicts: [String]
    package let ownedPaths: [LinuxNativePackageOwnedPath]
    package let lifecycle: LinuxNativePackageLifecycle

    package init(
        family: LinuxDistributionFamily,
        name: LinuxNativePackageName,
        version: String,
        architecture: String,
        summary: String,
        relationships: [LinuxNativePackageRelationship],
        conflicts: [String],
        ownedPaths: [LinuxNativePackageOwnedPath],
        lifecycle: LinuxNativePackageLifecycle
    ) {
        self.family = family
        self.name = name
        self.version = version
        self.architecture = architecture
        self.summary = summary
        self.relationships = relationships
        self.conflicts = conflicts
        self.ownedPaths = ownedPaths
        self.lifecycle = lifecycle
    }

    package var configurationFiles: [String] {
        ownedPaths.filter(\.configurationFile).map(\.path).sorted()
    }
}

package struct LinuxNativePackageCohortManifest: Codable, Equatable, Sendable {
    package let family: LinuxDistributionFamily
    package let canonicalVersion: String
    package let architecture: PlatformArchitecture
    package let runtimeArtifactDigest: ArtifactDigest
    package let browserPayloadDigest: ArtifactDigest
    package let browserBuildManifestDigest: ArtifactDigest
    package let packages: [LinuxNativePackageManifest]

    package init(
        family: LinuxDistributionFamily,
        canonicalVersion: String,
        architecture: PlatformArchitecture,
        runtimeArtifactDigest: ArtifactDigest,
        browserPayloadDigest: ArtifactDigest,
        browserBuildManifestDigest: ArtifactDigest,
        packages: [LinuxNativePackageManifest]
    ) {
        self.family = family
        self.canonicalVersion = canonicalVersion
        self.architecture = architecture
        self.runtimeArtifactDigest = runtimeArtifactDigest
        self.browserPayloadDigest = browserPayloadDigest
        self.browserBuildManifestDigest = browserBuildManifestDigest
        self.packages = packages
    }
}

package struct LinuxNativePackageCohortContract: Sendable {
    package let manifest: LinuxNativePackageCohortManifest

    package init(
        runtime: LinuxDistributionPackageManifest,
        browser: BrowserPackageInputManifest,
        architecture: PlatformArchitecture
    ) throws {
        let target = ArtifactTarget(
            operatingSystem: .linux,
            architecture: architecture,
            abi: "glibc")
        guard browser.packageName == LinuxNativePackageName.browser.rawValue,
            browser.artifactTarget == target,
            runtime.architecture
                == runtime.family.packageArchitecture(architecture),
            runtime.artifactDigest.hasPrefix("sha256:"),
            let runtimeDigest = ArtifactDigest(
                sha256Hex: String(runtime.artifactDigest.dropFirst("sha256:".count)))
        else {
            throw LinuxNativePackageContractFailure(
                "runtime and browser package inputs do not describe one target")
        }
        var versionIdentity = IdentityEncoder()
        versionIdentity.append("linux-native-package-cohort")
        versionIdentity.append(digest: runtimeDigest)
        versionIdentity.append(digest: browser.payloadDigest)
        versionIdentity.append(digest: browser.buildManifestDigest)
        let versionDigest = ArtifactDigest.sha256(versionIdentity.bytes)
        let canonicalVersion =
            "0.0.0-dev."
            + String(versionDigest.hexadecimal.prefix(16))
        let familyVersion = Self.packageVersion(
            canonicalVersion: canonicalVersion,
            family: runtime.family)
        let exactPackages: [LinuxNativePackageName] = [
            .runtime, .session, .browser,
        ]
        let exactRelationships = exactPackages.map {
            LinuxNativePackageRelationship(
                package: $0.rawValue,
                requirement: .exactCohort,
                version: familyVersion)
        }
        let runtimeRelationships = runtime.dependencies.map {
            LinuxNativePackageRelationship(
                package: $0,
                requirement: .runtimeCapability)
        }
        let browserRelationships = try Self.browserRuntimeRelationships(
            capabilities: browser.hostCapabilities,
            family: runtime.family)
        let runtimeGeneration = runtime.runtimeGeneration
        let browserGeneration =
            "/usr/lib/nucleus-browser/\(browser.payloadGeneration)"
        let desktopRefresh = [
            "update-desktop-database /usr/share/applications"
        ]
        let packages = [
            LinuxNativePackageManifest(
                family: runtime.family,
                name: .runtime,
                version: familyVersion,
                architecture: runtime.architecture,
                summary: "Nucleus immutable Linux runtime",
                relationships: runtimeRelationships,
                conflicts: [],
                ownedPaths: [
                    LinuxNativePackageOwnedPath(
                        path: runtimeGeneration,
                        kind: .tree)
                ],
                lifecycle: LinuxNativePackageLifecycle()),
            LinuxNativePackageManifest(
                family: runtime.family,
                name: .session,
                version: familyVersion,
                architecture: Self.neutralArchitecture(for: runtime.family),
                summary: "Nucleus login-session integration",
                relationships: [
                    LinuxNativePackageRelationship(
                        package: LinuxNativePackageName.runtime.rawValue,
                        requirement: .exactCohort,
                        version: familyVersion)
                ],
                conflicts: [],
                ownedPaths: runtime.installations.filter {
                    $0.kind != .tree
                }.map {
                    LinuxNativePackageOwnedPath(
                        path: $0.destination,
                        kind: LinuxNativePackagePathKind($0.kind),
                        symbolicLinkTarget: $0.target,
                        configurationFile: $0.destination == "/etc/pam.d/nucleus")
                },
                lifecycle: LinuxNativePackageLifecycle()),
            LinuxNativePackageManifest(
                family: runtime.family,
                name: .browser,
                version: familyVersion,
                architecture: runtime.architecture,
                summary: "Nucleus Chromium browser",
                relationships: browserRelationships,
                conflicts: [],
                ownedPaths: [
                    LinuxNativePackageOwnedPath(
                        path: browserGeneration,
                        kind: .tree),
                    LinuxNativePackageOwnedPath(
                        path: "/usr/lib/nucleus-browser/current",
                        kind: .symbolicLink,
                        symbolicLinkTarget: browser.payloadGeneration),
                    LinuxNativePackageOwnedPath(
                        path: "/usr/bin/nucleus-browser",
                        kind: .symbolicLink,
                        symbolicLinkTarget:
                            "../lib/nucleus-browser/current/bin/nucleus-browser"),
                    LinuxNativePackageOwnedPath(
                        path:
                            "/usr/share/applications/dev.nucleus.Browser.desktop",
                        kind: .file,
                        permissions: 0o644),
                ] + Self.browserIconPaths(),
                lifecycle: LinuxNativePackageLifecycle(
                    afterInstall: desktopRefresh,
                    afterRemove: desktopRefresh)),
            LinuxNativePackageManifest(
                family: runtime.family,
                name: .developmentHost,
                version: familyVersion,
                architecture: Self.neutralArchitecture(for: runtime.family),
                summary: "Host capabilities for Nucleus development generations",
                relationships: runtimeRelationships,
                conflicts: [],
                ownedPaths: [
                    LinuxNativePackageOwnedPath(
                        path: "/usr/share/nucleus/package-cohorts/development-host",
                        kind: .file,
                        permissions: 0o644)
                ],
                lifecycle: LinuxNativePackageLifecycle()),
            LinuxNativePackageManifest(
                family: runtime.family,
                name: .complete,
                version: familyVersion,
                architecture: Self.neutralArchitecture(for: runtime.family),
                summary: "Complete Nucleus installation",
                relationships: exactRelationships,
                conflicts: [],
                ownedPaths: [
                    LinuxNativePackageOwnedPath(
                        path: "/usr/share/nucleus/package-cohorts/complete",
                        kind: .file,
                        permissions: 0o644)
                ],
                lifecycle: LinuxNativePackageLifecycle()),
        ]
        manifest = LinuxNativePackageCohortManifest(
            family: runtime.family,
            canonicalVersion: canonicalVersion,
            architecture: architecture,
            runtimeArtifactDigest: runtimeDigest,
            browserPayloadDigest: browser.payloadDigest,
            browserBuildManifestDigest: browser.buildManifestDigest,
            packages: packages)
        try validate()
    }

    package func validate() throws {
        guard
            manifest.packages.map(\.name) == [
                .runtime, .session, .browser, .developmentHost, .complete,
            ]
        else {
            throw LinuxNativePackageContractFailure(
                "native package cohort is incomplete or unordered")
        }
        var owners: [String: LinuxNativePackageName] = [:]
        for package in manifest.packages {
            guard package.family == manifest.family,
                package.version
                    == Self.packageVersion(
                        canonicalVersion: manifest.canonicalVersion,
                        family: manifest.family)
            else {
                throw LinuxNativePackageContractFailure(
                    "native package does not match its cohort")
            }
            for relationship in package.relationships
            where relationship.requirement == .exactCohort {
                guard relationship.version == package.version else {
                    throw LinuxNativePackageContractFailure(
                        "cohort relationship is not exact: \(relationship.package)")
                }
            }
            for path in package.ownedPaths {
                _ = try validatedLinuxPackageAbsolutePath(path.path)
                if let previous = owners.updateValue(package.name, forKey: path.path) {
                    throw LinuxNativePackageContractFailure(
                        "\(previous.rawValue) and \(package.name.rawValue) both own \(path.path)"
                    )
                }
                if path.kind == .symbolicLink {
                    guard let target = path.symbolicLinkTarget,
                        path.permissions == nil
                    else {
                        throw LinuxNativePackageContractFailure(
                            "package symlink metadata is invalid: \(path.path)")
                    }
                    try validateLinuxPackageSymlinkTarget(
                        target,
                        at: path.path)
                } else if path.symbolicLinkTarget != nil {
                    throw LinuxNativePackageContractFailure(
                        "non-symlink package path declares a target: \(path.path)")
                }
            }
            try validateLinuxPackageLifecycle(package.lifecycle)
        }
    }

    package static func packageVersion(
        canonicalVersion: String,
        family: LinuxDistributionFamily
    ) -> String {
        switch family {
        case .debian:
            canonicalVersion.replacingOccurrences(of: "-dev.", with: "~dev.")
        case .rpm:
            canonicalVersion.replacingOccurrences(of: "-dev.", with: ".dev.")
                + "-1"
        case .arch:
            canonicalVersion.replacingOccurrences(of: "-dev.", with: ".dev.")
                + "-1"
        }
    }

    private static func neutralArchitecture(
        for family: LinuxDistributionFamily
    ) -> String {
        switch family {
        case .debian: "all"
        case .rpm: "noarch"
        case .arch: "any"
        }
    }

    private static func browserIconPaths() -> [LinuxNativePackageOwnedPath] {
        [16, 22, 24, 32, 48, 64, 128, 256].map { size in
            LinuxNativePackageOwnedPath(
                path:
                    "/usr/share/icons/hicolor/\(size)x\(size)/apps/"
                    + "dev.nucleus.Browser.png",
                kind: .symbolicLink,
                symbolicLinkTarget:
                    "../../../../../lib/nucleus-browser/current/share/icons/"
                    + "hicolor/\(size)x\(size)/apps/dev.nucleus.Browser.png")
        } + [
            LinuxNativePackageOwnedPath(
                path: "/usr/libexec/nucleus-browser/chrome-sandbox",
                kind: .file,
                permissions: 0o4755)
        ]
    }

    private static func browserRuntimeRelationships(
        capabilities: [String],
        family: LinuxDistributionFamily
    ) throws -> [LinuxNativePackageRelationship] {
        let packages: [String: [String]] =
            switch family {
            case .debian:
                [
                    "audio.alsa": ["libasound2"],
                    "desktop.at-spi": ["libatk-bridge2.0-0"],
                    "desktop.gtk3": ["libgtk-3-0"],
                    "device.udev": ["libudev1"],
                    "font.fontconfig": ["libfontconfig1"],
                    "font.pango": ["libpango-1.0-0"],
                    "graphics.cairo": ["libcairo2"],
                    "graphics.gbm": ["libgbm1"],
                    "ipc.dbus": ["libdbus-1-3"],
                    "network.nss": ["libnspr4", "libnss3"],
                    "printing.cups": ["libcups2"],
                    "runtime.expat": ["libexpat1"],
                    "runtime.glib": ["libglib2.0-0"],
                    "x11.compatibility": [
                        "libx11-6", "libxcb1", "libxcomposite1", "libxdamage1",
                        "libxext6", "libxfixes3", "libxrandr2",
                    ],
                    "xkb.common": ["libxkbcommon0"],
                ]
            case .rpm:
                [
                    "audio.alsa": ["alsa-lib"],
                    "desktop.at-spi": ["at-spi2-atk"],
                    "desktop.gtk3": ["gtk3"],
                    "device.udev": ["systemd-libs"],
                    "font.fontconfig": ["fontconfig"],
                    "font.pango": ["pango"],
                    "graphics.cairo": ["cairo"],
                    "graphics.gbm": ["mesa-libgbm"],
                    "ipc.dbus": ["dbus-libs"],
                    "network.nss": ["nspr", "nss"],
                    "printing.cups": ["cups-libs"],
                    "runtime.expat": ["expat"],
                    "runtime.glib": ["glib2"],
                    "x11.compatibility": [
                        "libX11", "libXcomposite", "libXdamage", "libXext",
                        "libXfixes", "libXrandr", "libxcb",
                    ],
                    "xkb.common": ["libxkbcommon"],
                ]
            case .arch:
                [
                    "audio.alsa": ["alsa-lib"],
                    "desktop.at-spi": ["at-spi2-core"],
                    "desktop.gtk3": ["gtk3"],
                    "device.udev": ["systemd-libs"],
                    "font.fontconfig": ["fontconfig"],
                    "font.pango": ["pango"],
                    "graphics.cairo": ["cairo"],
                    "graphics.gbm": ["mesa"],
                    "ipc.dbus": ["dbus"],
                    "network.nss": ["nspr", "nss"],
                    "printing.cups": ["cups"],
                    "runtime.expat": ["expat"],
                    "runtime.glib": ["glib2"],
                    "x11.compatibility": [
                        "libx11", "libxcb", "libxcomposite", "libxdamage",
                        "libxext", "libxfixes", "libxrandr",
                    ],
                    "xkb.common": ["libxkbcommon"],
                ]
            }
        var dependencies: Set<String> = ["bash"]
        for capability in capabilities {
            guard let mapped = packages[capability] else {
                throw LinuxNativePackageContractFailure(
                    "browser capability has no \(family.rawValue) mapping: "
                        + capability)
            }
            dependencies.formUnion(mapped)
        }
        return dependencies.sorted().map {
            LinuxNativePackageRelationship(
                package: $0,
                requirement: .runtimeCapability)
        }
    }

}

package func validateRuntimePackageInput(
    _ manifest: LinuxDistributionPackageManifest,
    activeGeneration: String,
    activeDigest: ArtifactDigest
) throws {
    for installation in manifest.installations {
        _ = try validatedLinuxPackageAbsolutePath(installation.destination)
        if installation.kind == .symbolicLink {
            guard let target = installation.target else {
                throw LinuxNativePackageContractFailure(
                    "runtime package symlink has no target: \(installation.destination)")
            }
            try validateLinuxPackageSymlinkTarget(
                target,
                at: installation.destination)
        }
    }
    for removal in manifest.removals {
        _ = try validatedLinuxPackageAbsolutePath(removal)
    }
    let generation = "/opt/nucleus/generations/\(activeGeneration)"
    guard manifest.artifactDigest == activeDigest.description,
        manifest.runtimeRoot == LinuxDistributionFamily.runtimeRoot,
        manifest.runtimeGeneration == generation,
        manifest.installations.contains(where: {
            $0.kind == .tree && $0.destination == generation
        }),
        manifest.installations.contains(where: {
            $0.kind == .symbolicLink
                && $0.destination == LinuxDistributionFamily.runtimeRoot
                && $0.target == generation
        })
    else {
        throw LinuxNativePackageContractFailure(
            "runtime package manifest does not bind the active immutable payload")
    }
}

package func validatedLinuxPackageAbsolutePath(_ value: String) throws -> FilePath {
    let components = value.split(
        separator: "/",
        omittingEmptySubsequences: false)
    let path = FilePath(value)
    guard value != "/", value.hasPrefix("/"), !value.hasSuffix("/"),
        !value.contains("//"),
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
        components.first?.isEmpty == true,
        components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
        path.isAbsolute,
        path.lexicallyNormalized() == path
    else {
        throw LinuxNativePackageContractFailure(
            "package owns an unsafe path: \(value)")
    }
    return path
}

package func validateLinuxPackageSymlinkTarget(
    _ target: String,
    at linkPath: String
) throws {
    let root = FilePath("/package-root")
    let installedLink = try installedLinuxPackagePath(linkPath, in: root)
    let targetPath = FilePath(target)
    let components = target.split(
        separator: "/",
        omittingEmptySubsequences: false)
    guard !target.isEmpty, target != ".", target != "..",
        !target.hasSuffix("/"), !target.hasSuffix("/.."),
        !target.contains("//"),
        !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        !target.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
        components.allSatisfy({ $0 != "." }),
        targetPath.string == target,
        targetPath.lexicallyNormalized() == targetPath
    else {
        throw LinuxNativePackageContractFailure(
            "package symlink has an unsafe target: \(linkPath) -> \(target)")
    }
    let resolved: FilePath
    if targetPath.isAbsolute {
        resolved = try installedLinuxPackagePath(target, in: root)
    } else {
        resolved = installedLink.removingLastComponent().appending(target)
            .lexicallyNormalized()
    }
    guard resolved != root, resolved.isContained(in: root) else {
        throw LinuxNativePackageContractFailure(
            "package symlink escapes its staging root: \(linkPath) -> \(target)")
    }
}

package func installedLinuxPackagePath(
    _ absolute: String,
    in root: FilePath
) throws -> FilePath {
    let path = try validatedLinuxPackageAbsolutePath(absolute)
    let normalizedRoot = root.lexicallyNormalized()
    let installed = normalizedRoot.appending(path.components).lexicallyNormalized()
    guard installed != normalizedRoot, installed.isContained(in: normalizedRoot) else {
        throw LinuxNativePackageContractFailure(
            "package path escapes its staging root: \(absolute)")
    }
    return installed
}

private func validateLinuxPackageLifecycle(
    _ lifecycle: LinuxNativePackageLifecycle
) throws {
    let safeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-/")
    for command in lifecycle.afterInstall + lifecycle.afterRemove {
        let fields = command.split(separator: " ", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.allSatisfy({ !$0.isEmpty }),
            fields.allSatisfy({ field in
                field.unicodeScalars.allSatisfy(safeCharacters.contains)
            }),
            !fields[0].contains("/")
        else {
            throw LinuxNativePackageContractFailure(
                "package lifecycle command is unsafe: \(command)")
        }
        for field in fields.dropFirst() where field.hasPrefix("/") {
            _ = try validatedLinuxPackageAbsolutePath(String(field))
        }
    }
}

extension LinuxNativePackagePathKind {
    fileprivate init(_ kind: LinuxPackageInstallation.Kind) {
        switch kind {
        case .file: self = .file
        case .symbolicLink: self = .symbolicLink
        case .tree: self = .tree
        }
    }
}

private struct LinuxNativePackageContractFailure: Error,
    CustomStringConvertible, Sendable
{
    let description: String

    init(_ description: String) {
        self.description = "Linux native package contract failed: \(description)"
    }
}
