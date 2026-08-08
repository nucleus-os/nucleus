#if os(macOS)
import ArgumentParser
import Testing

@testable import ColliderCLI
@testable import ColliderWorkspaceCommands

@Test
func macOSCommandCompositionContainsOnlyWorkspaceOperations() {
    let expectedRoot: [ParsableCommand.Type] = [
        Doctor.self, Bootstrap.self, Build.self, Test.self,
        Install.self, SwiftSDK.self, Android.self, AndroidRuntime.self,
        Browser.self, Generate.self, Sanitize.self, Benchmark.self,
        Clean.self, Cache.self, Logs.self, Status.self,
    ]
    let expectedInstall: [ParsableCommand.Type] = [InstallBrowser.self]
    let expectedAndroidRuntime: [ParsableCommand.Type] = [
        AndroidRuntimeSourceLock.self,
        AndroidRuntimeSource.self,
        AndroidRuntimeImage.self,
    ]

    #expect(commandTypes(ColliderCommand.configuration.subcommands) == commandTypes(expectedRoot))
    #expect(commandTypes(Install.configuration.subcommands) == commandTypes(expectedInstall))
    #expect(
        commandTypes(AndroidRuntime.configuration.subcommands)
            == commandTypes(expectedAndroidRuntime))
}

private func commandTypes(
    _ commands: [ParsableCommand.Type]
) -> [ObjectIdentifier] {
    commands.map { ObjectIdentifier($0) }
}
#endif
