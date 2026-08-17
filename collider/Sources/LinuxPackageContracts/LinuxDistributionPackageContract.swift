import ColliderCore

package enum LinuxDistributionFamily: String, CaseIterable, Codable, Hashable, Sendable {
    case debian
    case rpm
    case arch

    package static let runtimeRoot = "/opt/nucleus/current"

    package func packageArchitecture(
        _ architecture: PlatformArchitecture
    ) -> String {
        switch (self, architecture) {
        case (.debian, .arm64): "arm64"
        case (.debian, .x86_64): "amd64"
        case (.rpm, .arm64), (.arch, .arm64): "aarch64"
        case (.rpm, .x86_64), (.arch, .x86_64): "x86_64"
        }
    }
}

package struct LinuxPackageInstallation: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case file
        case symbolicLink
        case tree
    }

    package let source: String?
    package let destination: String
    package let kind: Kind
    package let target: String?
    package let contents: String?

    package init(
        source: String?,
        destination: String,
        kind: Kind,
        target: String?,
        contents: String?
    ) {
        self.source = source
        self.destination = destination
        self.kind = kind
        self.target = target
        self.contents = contents
    }

    package static func file(_ destination: String, contents: String) -> Self {
        Self(
            source: nil,
            destination: destination,
            kind: .file,
            target: nil,
            contents: contents)
    }

    package static func symbolicLink(_ destination: String, target: String) -> Self {
        Self(
            source: nil,
            destination: destination,
            kind: .symbolicLink,
            target: target,
            contents: nil)
    }
}

package struct LinuxDistributionPackageManifest: Codable, Equatable, Sendable {
    package let family: LinuxDistributionFamily
    package let architecture: String
    package let artifactDigest: String
    package let runtimeRoot: String
    package let runtimeGeneration: String
    package let seatPolicy: String
    package let capabilityPackages: [String: [String]]
    package let dependencies: [String]
    package let installations: [LinuxPackageInstallation]
    package let removals: [String]

    package init(
        family: LinuxDistributionFamily,
        architecture: String,
        artifactDigest: String,
        runtimeRoot: String,
        runtimeGeneration: String,
        seatPolicy: String,
        capabilityPackages: [String: [String]],
        dependencies: [String],
        installations: [LinuxPackageInstallation],
        removals: [String]
    ) {
        self.family = family
        self.architecture = architecture
        self.artifactDigest = artifactDigest
        self.runtimeRoot = runtimeRoot
        self.runtimeGeneration = runtimeGeneration
        self.seatPolicy = seatPolicy
        self.capabilityPackages = capabilityPackages
        self.dependencies = dependencies
        self.installations = installations
        self.removals = removals
    }
}
