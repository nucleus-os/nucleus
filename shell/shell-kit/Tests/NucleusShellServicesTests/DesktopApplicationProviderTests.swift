import Foundation
import Testing

@testable import NucleusShellServices

@MainActor
@Suite("Desktop application provider")
struct DesktopApplicationProviderTests {
    @Test("discovery is recursive, precedence-aware, filtered, and naturally sorted")
    func discoveryContract() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory.appendingPathComponent(
            "nucleus-desktop-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: fixture) }

        let userData = fixture.appendingPathComponent("user", isDirectory: true)
        let systemData = fixture.appendingPathComponent("system", isDirectory: true)
        let userApplications = userData.appendingPathComponent(
            "applications/nested", isDirectory: true)
        let systemApplications = systemData.appendingPathComponent(
            "applications", isDirectory: true)
        try fileManager.createDirectory(
            at: userApplications, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: systemApplications, withIntermediateDirectories: true)

        try writeDesktopFile(
            to: userApplications.appendingPathComponent("app-10.desktop"),
            name: "App 10", executable: "/usr/bin/app-ten %U --mode=test")
        try writeDesktopFile(
            to: userApplications.appendingPathComponent("app-2.desktop"),
            name: "App 2", executable: "/usr/bin/app-two %f")
        try writeDesktopFile(
            to: userData.appendingPathComponent("applications/shared.desktop"),
            name: "User Shared", executable: "/usr/bin/user-shared")
        try writeDesktopFile(
            to: systemApplications.appendingPathComponent("shared.desktop"),
            name: "System Shared", executable: "/usr/bin/system-shared")
        try writeDesktopFile(
            to: systemApplications.appendingPathComponent("hidden.desktop"),
            name: "Hidden", executable: "/usr/bin/hidden", hidden: true)

        let provider = DesktopApplicationProvider(
            environment: [
                "XDG_DATA_HOME": userData.path,
                "XDG_DATA_DIRS": systemData.path,
            ],
            fileManager: fileManager)

        #expect(provider.applications.map(\.name) == ["App 2", "App 10", "User Shared"])
        #expect(
            provider.applications.map(\.id.rawValue) == [
                "desktop:nested-app-2.desktop",
                "desktop:nested-app-10.desktop",
                "desktop:shared.desktop",
            ])
        #expect(
            provider.applications.last?.icon == nil)
        #expect(provider.applications.allSatisfy { $0.name != "Hidden" })
    }

    private func writeDesktopFile(
        to url: URL,
        name: String,
        executable: String,
        hidden: Bool = false
    ) throws {
        let contents = """
            [Desktop Entry]
            Type=Application
            Name=\(name)
            Exec=\(executable)
            Hidden=\(hidden)
            """
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}
