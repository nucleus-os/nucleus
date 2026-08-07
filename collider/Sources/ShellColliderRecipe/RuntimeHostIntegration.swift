import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

package struct RuntimeHostRequirements: Codable, Equatable, Sendable {
    package let architecture: String
    package let minimumGlibcVersion: String
    package let serviceManager: String
    package let pamService: String
    package let sessionBus: String
    package let requiredCapabilities: [String]
    package let requiredExecutables: [String]
    package let hostLibraries: [String]

    package init(architecture: PlatformArchitecture) {
        self.architecture = architecture.rawValue
        minimumGlibcVersion = NucleusLinuxABI.minimumGlibcVersion
        serviceManager = "systemd"
        pamService = "nucleus"
        sessionBus = "private-dbus-run-session"
        requiredCapabilities = [
            "dbus.session",
            "drm.kms",
            "input.libinput",
            "pam.authentication",
            "seat.libseat",
            "udev.devices",
            "vulkan.loader",
            "wayland",
            "xwayland",
        ]
        requiredExecutables = ["bash", "dbus-run-session"]
        let dynamicLoader =
            switch architecture {
            case .arm64: "ld-linux-aarch64.so.1"
            case .x86_64: "ld-linux-x86-64.so.2"
            }
        hostLibraries = NucleusLinuxABI.hostOwnedSONames.filter {
            !$0.hasPrefix("ld-linux-") || $0 == dynamicLoader
        }.sorted()
    }
}

package enum RuntimeHostIntegration {
    package static let sourceFiles = [
        "nucleus-session",
        "nucleus-session-validate",
        "nucleus@.service",
        "nucleus-wayland.desktop",
        "nucleus.pam.in",
    ]

    package static func render(
        _ template: String,
        activePrefix: FilePath
    ) -> String {
        template.replacing(
            "@bindir@",
            with: activePrefix.appending("bin").string)
    }

    package struct PayloadFile: Equatable, Sendable {
        package let path: String
        package let bytes: [UInt8]
        package let executable: Bool
    }

    package static func payload(
        source: [String: [UInt8]],
        activePrefix: FilePath,
        architecture: PlatformArchitecture
    ) throws -> [PayloadFile] {
        func text(_ name: String) throws -> String {
            guard let bytes = source[name] else {
                throw RuntimeHostIntegrationFailure("missing source file \(name)")
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        let unit = render(
            try text("nucleus@.service"),
            activePrefix: activePrefix)
        try validatePublishedTemplate(
            unit,
            activePrefix: activePrefix,
            name: "nucleus@.service")
        let desktop = render(
            try text("nucleus-wayland.desktop"),
            activePrefix: activePrefix)
        try validatePublishedTemplate(
            desktop,
            activePrefix: activePrefix,
            name: "nucleus-wayland.desktop")
        let pam = try text("nucleus.pam.in")
        try validatePAMTemplate(pam)

        return [
            PayloadFile(
                path: "bin/nucleus-session",
                bytes: Array(try text("nucleus-session").utf8),
                executable: true),
            PayloadFile(
                path: "bin/nucleus-session-validate",
                bytes: Array(try text("nucleus-session-validate").utf8),
                executable: true),
            PayloadFile(
                path: "share/systemd/user/nucleus@.service",
                bytes: Array(unit.utf8),
                executable: false),
            PayloadFile(
                path: "share/wayland-sessions/nucleus.desktop",
                bytes: Array(desktop.utf8),
                executable: false),
            PayloadFile(
                path: "share/nucleus/host-integration/pam/nucleus.pam.in",
                bytes: Array(pam.utf8),
                executable: false),
            PayloadFile(
                path: "share/nucleus/host-requirements.json",
                bytes: try requirementsJSON(architecture: architecture),
                executable: false),
        ]
    }

    package static func requirementsJSON(
        architecture: PlatformArchitecture
    ) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Array(
            try encoder.encode(
                RuntimeHostRequirements(architecture: architecture)))
        bytes.append(0x0a)
        return bytes
    }

    package static func validatePublishedTemplate(
        _ value: String,
        activePrefix: FilePath,
        name: String
    ) throws {
        guard !value.contains("@bindir@") else {
            throw RuntimeHostIntegrationFailure(
                "\(name) retains the unresolved executable prefix")
        }
        let expected = activePrefix.appending("bin").string
        guard value.contains(expected) else {
            throw RuntimeHostIntegrationFailure(
                "\(name) does not reference the active runtime prefix")
        }
    }

    package static func validatePAMTemplate(_ value: String) throws {
        guard value.contains("auth include @authentication-stack@"),
            value.contains("account include @account-stack@")
        else {
            throw RuntimeHostIntegrationFailure(
                "nucleus.pam.in does not declare both distribution-owned PAM stacks")
        }
        guard !value.contains("include login") else {
            throw RuntimeHostIntegrationFailure(
                "nucleus.pam.in must not fall back to the generic login service")
        }
    }
}

package struct RuntimeHostIntegrationFailure: Error, CustomStringConvertible {
    package let description: String

    package init(_ description: String) {
        self.description = "runtime host integration failed: \(description)"
    }
}
