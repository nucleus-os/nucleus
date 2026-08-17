import ColliderCore
import ColliderPersistence
import ColliderWorkspaceCommands

actor GitHubActionsRunReporter {
    private let console: CommandConsole
    private let registry: RunRegistry
    private let run: RunHandle

    init(
        console: CommandConsole,
        registry: RunRegistry,
        run: RunHandle
    ) {
        self.console = console
        self.registry = registry
        self.run = run
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
            try? console.githubFailure(
                task: task,
                reason: failure.reason,
                logPath: failure.logPath ?? path)
        }
    }
}
