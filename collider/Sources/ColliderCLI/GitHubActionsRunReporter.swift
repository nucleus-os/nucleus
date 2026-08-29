import ColliderCore
import ColliderPersistence
import ColliderWorkspaceCommands
import Foundation
import SystemPackage

actor GitHubActionsRunReporter {
    private let console: CommandConsole
    private let registry: RunRegistry
    private let run: RunHandle
    private let workspaceRoot: FilePath

    init(
        console: CommandConsole,
        registry: RunRegistry,
        run: RunHandle,
        workspaceRoot: FilePath
    ) {
        self.console = console
        self.registry = registry
        self.run = run
        self.workspaceRoot = workspaceRoot
    }

    func consume(_ observation: RunObservation) async {
        guard console.progressPresentation == .githubActions,
            case .event(let event) = observation,
            case .task(let taskEvent) = event.payload
        else { return }

        let task: TaskID
        let failure: ExecutionFailure?
        switch taskEvent {
        case .succeeded(let succeeded), .cancelled(let succeeded):
            task = succeeded
            failure = nil
        case .failed(let failed, let executionFailure):
            task = failed
            failure = executionFailure
        case .started, .skipped:
            return
        }

        let path = await registry.stageLogPath(for: task, in: run).string
        try? console.githubTaskLog(task: task, path: path)
        if let failure {
            let logPath = failure.logPath ?? path
            try? console.githubFailure(
                task: task,
                reason: failure.reason,
                logPath: logPath,
                diagnostic: diagnostic(inStageLogAt: logPath))
        }
    }

    /// Locate the source line a failing stage log blames, if it names one that
    /// resolves inside the checkout.
    private func diagnostic(inStageLogAt path: String) -> ResolvedSourceDiagnostic? {
        guard
            let data = try? Data(
                contentsOf: URL(fileURLWithPath: path),
                options: .mappedIfSafe)
        else { return nil }
        return SourceDiagnosticLocator.firstDiagnostic(
            in: String(decoding: data, as: UTF8.self),
            repositoryRoot: workspaceRoot.string)
    }
}
