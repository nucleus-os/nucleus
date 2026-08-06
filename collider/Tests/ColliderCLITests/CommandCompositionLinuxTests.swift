#if os(Linux)
import ArgumentParser
import Testing

@testable import ColliderCLI
@testable import ColliderLinuxOperations
@testable import ColliderWorkspaceCommands

@Test
func linuxCommandCompositionAddsOnlyInstalledHostOperations() {
    let expectedRoot: [ParsableCommand.Type] = [
        Doctor.self, Bootstrap.self, Build.self, Test.self, Run.self,
        Install.self, SwiftSDK.self, Android.self, AndroidRuntime.self,
        Browser.self, Generate.self, Sanitize.self, Benchmark.self,
        Cache.self, Logs.self, Status.self,
    ]
    let expectedInstall: [ParsableCommand.Type] = [
        InstallSession.self, InstallAndroidAddon.self, InstallBrowser.self,
    ]
    let expectedAndroidRuntime: [ParsableCommand.Type] = [
        AndroidRuntimeSourceLock.self,
        AndroidRuntimeSource.self,
        AndroidRuntimeImage.self,
        AndroidRuntimePackageAddon.self,
    ]

    #expect(commandTypes(ColliderCommand.configuration.subcommands) == commandTypes(expectedRoot))
    #expect(commandTypes(Install.configuration.subcommands) == commandTypes(expectedInstall))
    #expect(
        commandTypes(AndroidRuntime.configuration.subcommands)
            == commandTypes(expectedAndroidRuntime))
}

@Test
func runRemainsAControlFreeSessionLaunchOperation() {
    awaitRejectsTaskControls(["run"])
}

@Test
func privilegedAndroidOperationsStayOutOfColliderRootHelp() {
    let rootHelp = ColliderCommand.message(for: CleanExit.helpRequest())
    for command in [
        "android-apex-mount",
        "android-bpf-broker",
        "android-bpf-mount",
        "android-cgroup-delegate",
    ] {
        #expect(!rootHelp.contains(command))
    }
}

private func awaitRejectsTaskControls(_ path: [String]) {
    for option in [
        ["--dry-run"],
        ["--rebuild"],
        ["--explain"],
        ["--verbose"],
        ["--quiet"],
        ["--json"],
        ["--run-id", "not-supported"],
    ] {
        #expect(throws: (any Error).self) {
            try ColliderCommand.parseAsRoot(path + option)
        }
    }
}

private func commandTypes(
    _ commands: [ParsableCommand.Type]
) -> [ObjectIdentifier] {
    commands.map { ObjectIdentifier($0) }
}
#endif
