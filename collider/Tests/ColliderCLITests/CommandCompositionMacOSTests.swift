#if os(macOS)
import ArgumentParser
import Testing

@testable import ColliderCLI
@testable import ColliderWorkspaceCommands

@Test
func macOSCommandCompositionContainsOnlyWorkspaceOperations() {
    let expectedRoot: [ParsableCommand.Type] = [
        Doctor.self, Bootstrap.self, Build.self, Test.self, Check.self, Generate.self,
        Install.self, Benchmark.self,
        Clean.self, Cache.self, Tasks.self, Graph.self, Runs.self, Logs.self,
        Status.self,
    ]
    let expectedInstall: [ParsableCommand.Type] = [InstallBrowser.self]

    #expect(commandTypes(ColliderCommand.configuration.subcommands) == commandTypes(expectedRoot))
    #expect(commandTypes(Install.configuration.subcommands) == commandTypes(expectedInstall))
}

private func commandTypes(
    _ commands: [ParsableCommand.Type]
) -> [ObjectIdentifier] {
    commands.map { ObjectIdentifier($0) }
}
#endif
