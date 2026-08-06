import ArgumentParser

package enum WorkspaceCommandSet {
    package static let rootPrefix: [ParsableCommand.Type] = [
        Doctor.self,
        Bootstrap.self,
        Build.self,
        Test.self,
    ]

    package static let rootBetweenGroups: [ParsableCommand.Type] = [
        SwiftSDK.self,
        Android.self,
    ]

    package static let rootSuffix: [ParsableCommand.Type] = [
        Browser.self,
        Generate.self,
        Sanitize.self,
        Benchmark.self,
        Cache.self,
        Logs.self,
        Status.self,
    ]

    package static let install: [ParsableCommand.Type] = [
        InstallBrowser.self
    ]

    package static let androidRuntime: [ParsableCommand.Type] = [
        AndroidRuntimeSourceLock.self,
        AndroidRuntimeSource.self,
        AndroidRuntimeImage.self,
    ]
}
