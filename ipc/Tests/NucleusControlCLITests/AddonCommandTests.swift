import ArgumentParser
import Testing

@testable import NucleusControlCLI

@Test func addonCommandsUseSystemProductLocationsByDefault() throws {
    let parsed = try NucleusCommand.parseAsRoot([
        "addon", "status",
    ])
    let status = try #require(parsed as? Addon.Status)

    #expect(status.locations.basePrefix == "/opt/nucleus/current")
    #expect(status.locations.storeRoot == "/opt/nucleus/addons/android")
    #expect(status.locations.stateRoot == "/var/lib/nucleus/android")
}

@Test func addonInstallAcceptsExplicitRecoveryLocationsAndTrustRoot() throws {
    let parsed = try NucleusCommand.parseAsRoot([
        "addon", "install", "/downloads/android",
        "--base-prefix", "/recovery/base",
        "--store-root", "/recovery/addons/android",
        "--state-root", "/recovery/state/android",
        "--trust-key", "/recovery/trust.pem",
    ])
    let install = try #require(parsed as? Addon.Install)

    #expect(install.artifact == "/downloads/android")
    #expect(install.locations.basePrefix == "/recovery/base")
    #expect(install.locations.storeRoot == "/recovery/addons/android")
    #expect(install.locations.stateRoot == "/recovery/state/android")
    #expect(install.trustKey == "/recovery/trust.pem")
}
