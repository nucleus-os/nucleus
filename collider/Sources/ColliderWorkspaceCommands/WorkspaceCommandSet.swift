import ArgumentParser

package enum WorkspaceCommandSet {
    package static let rootPrefix: [ParsableCommand.Type] = [
        Doctor.self,
        Bootstrap.self,
        Build.self,
        Test.self,
        Check.self,
        Generate.self,
    ]

    package static let rootSuffix: [ParsableCommand.Type] = [
        Benchmark.self,
        Clean.self,
        Cache.self,
        Tasks.self,
        Graph.self,
        Runs.self,
        Logs.self,
        Status.self,
    ]

    package static let install: [ParsableCommand.Type] = [
        InstallBrowser.self
    ]

}
