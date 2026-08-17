import ColliderCore

public enum TaskOutputPresentation: Sendable {
    case `default`
    case verbose
    case quiet
    case raw

    func output(for output: CommandSpec.Output) -> CommandSpec.Output {
        switch (self, output) {
        case (.default, .inherited), (.quiet, .inherited):
            .logged
        case (.verbose, .logged):
            .inherited
        case (.raw, _):
            .terminal
        case (.default, .logged), (.default, .terminal), (.default, .file),
            (.default, .captured), (.default, .combined), (.verbose, .inherited),
            (.verbose, .terminal), (.verbose, .file), (.verbose, .captured),
            (.verbose, .combined), (.quiet, .logged), (.quiet, .terminal),
            (.quiet, .file), (.quiet, .captured), (.quiet, .combined):
            output
        }
    }
}

public enum TaskOutputStream: Hashable, Sendable {
    case standardOutput
    case standardError
}

public enum TaskOutputEvent: Sendable {
    case chunk(
        task: TaskID?,
        stream: TaskOutputStream,
        bytes: [UInt8],
        presentation: TaskOutputPresentation)
    case finished(task: TaskID?, presentation: TaskOutputPresentation)
}

public struct TaskOutputObserver: Sendable {
    public let output: @Sendable (TaskOutputEvent) -> Void
    public let terminalWillBegin: @Sendable () -> Void
    public let terminalDidEnd: @Sendable () -> Void

    public init(
        output: @escaping @Sendable (TaskOutputEvent) -> Void = { _ in },
        terminalWillBegin: @escaping @Sendable () -> Void = {},
        terminalDidEnd: @escaping @Sendable () -> Void = {}
    ) {
        self.output = output
        self.terminalWillBegin = terminalWillBegin
        self.terminalDidEnd = terminalDidEnd
    }
}
