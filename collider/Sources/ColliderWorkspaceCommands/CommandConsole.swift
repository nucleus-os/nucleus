import ColliderCore
import ColliderRuntime
import Foundation
import Synchronization

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

package enum ConsoleOutputFormat: String, CaseIterable, Sendable {
    case text
    case json
}

package enum ConsoleColorPolicy: String, CaseIterable, Sendable {
    case auto
    case always
    case never
}

package enum ConsoleProgressPolicy: String, CaseIterable, Sendable {
    case auto
    case always
    case never
}

package enum ConsoleProgressFormat: String, CaseIterable, Sendable {
    case human
    case json
}

package enum CommandPresentationKind: Equatable, Sendable {
    case taskGraph
    case phase
    case none
}

package enum ConsoleProgressPresentation: Equatable, Sendable {
    case disabled
    case appendOnly
    case dynamic
    case githubActions
    case machine
}

package enum ConsoleHumanDestination: Equatable, Sendable {
    case standardOutput
    case standardError
}

package final class CommandConsole: @unchecked Sendable {
    package typealias Writer = @Sendable (Data) throws -> Void
    package typealias GeometryProvider = @Sendable () -> TerminalGeometry

    package let format: ConsoleOutputFormat
    package let colorEnabled: Bool
    package let progressPresentation: ConsoleProgressPresentation
    package let presentationKind: CommandPresentationKind

    private struct TaskOutputBufferKey: Hashable {
        let task: TaskID?
        let stream: TaskOutputStream
    }

    private struct State {
        var logicalProgressLines: [String] = []
        var progressSnapshot: RunProgressSnapshot?
        var taskOutputBuffers: [TaskOutputBufferKey: [UInt8]] = [:]
        var taskOutputTails: [TaskID: [String]] = [:]
        var latestTaskOutput: [TaskID: String] = [:]
        var taskLabels: [TaskID: String] = [:]
        var renderedLineCount = 0
        var cursorHidden = false
        var suspended = false
        var githubSummaryWritten = false
    }

    private enum Style {
        case red
    }

    private let standardOutput: Writer
    private let standardError: Writer
    private let standardOutputIsTerminal: Bool
    private let githubStepSummaryPath: String?
    private let geometry: GeometryProvider
    private let state = Mutex(State())

    package init(
        format: ConsoleOutputFormat = .text,
        color: ConsoleColorPolicy = .auto,
        progress: ConsoleProgressPolicy = .auto,
        progressFormat: ConsoleProgressFormat? = nil,
        presentationKind: CommandPresentationKind = .taskGraph,
        dryRun: Bool = false,
        standardOutputIsTerminal: Bool = false,
        standardErrorIsTerminal: Bool = false,
        environment: [String: String] = [:],
        geometry: @escaping GeometryProvider = {
            TerminalGeometry(columns: 80, rows: 24)
        },
        standardOutput: @escaping Writer,
        standardError: @escaping Writer
    ) {
        self.format = format
        self.presentationKind = presentationKind
        colorEnabled =
            switch color {
            case .auto: standardErrorIsTerminal && environment["NO_COLOR"] == nil
            case .always: environment["NO_COLOR"] == nil
            case .never: false
            }
        progressPresentation =
            if presentationKind == .none || dryRun || progress == .never {
                .disabled
            } else if progressFormat == .json {
                .machine
            } else if format == .json {
                .disabled
            } else if environment["GITHUB_ACTIONS"] == "true" {
                .githubActions
            } else {
                standardErrorIsTerminal ? .dynamic : .appendOnly
            }
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputIsTerminal = standardOutputIsTerminal
        githubStepSummaryPath = environment["GITHUB_STEP_SUMMARY"].flatMap {
            $0.isEmpty ? nil : $0
        }
        self.geometry = geometry
    }

    package static func process(
        options: CommandOutputOptions,
        presentationKind: CommandPresentationKind,
        dryRun: Bool,
        environment: [String: String],
        standardOutputIsTerminal: Bool,
        standardErrorIsTerminal: Bool
    ) -> CommandConsole {
        CommandConsole(
            format: options.format,
            color: options.color,
            progress: options.progress,
            progressFormat: options.progressFormat,
            presentationKind: presentationKind,
            dryRun: dryRun,
            standardOutputIsTerminal: standardOutputIsTerminal,
            standardErrorIsTerminal: standardErrorIsTerminal,
            environment: environment,
            geometry: {
                terminalGeometry(descriptor: STDERR_FILENO)
                    ?? TerminalGeometry(columns: 80, rows: 24)
            },
            standardOutput: { try FileHandle.standardOutput.write(contentsOf: $0) },
            standardError: { try FileHandle.standardError.write(contentsOf: $0) })
    }

    package static var processDefault: CommandConsole {
        CommandConsole(
            standardOutputIsTerminal: false,
            standardErrorIsTerminal: false,
            environment: ProcessInfo.processInfo.environment,
            standardOutput: { try FileHandle.standardOutput.write(contentsOf: $0) },
            standardError: { try FileHandle.standardError.write(contentsOf: $0) })
    }

    package func report<Value: Encodable>(
        _ value: Value,
        text: String,
        humanDestination: ConsoleHumanDestination = .standardOutput
    ) throws {
        if format == .json {
            var bytes = try scrubbedJSON(value)
            bytes.append(0x0A)
            try writeToStandardOutput(bytes)
        } else {
            try human(text, destination: humanDestination)
        }
    }

    package func human(
        _ text: String,
        destination: ConsoleHumanDestination = .standardOutput
    ) throws {
        try human(text, destination: destination, style: nil)
    }

    package func rawReport(_ text: String) throws {
        try write(
            Data(CredentialScrubber.bytes(Array(text.utf8))),
            destination: .standardOutput)
    }

    package func diagnostic(_ text: String) throws {
        try human(text, destination: .standardError)
    }

    package func failure(_ error: any Error) throws {
        if let failure = error as? ExecutionFailure {
            try self.failure(failure)
            return
        }
        try failure(
            ExecutionFailure(reason: String(describing: error)))
    }

    package func failure(_ failure: ExecutionFailure) throws {
        var lines = ["error: \(failure.reason)"]
        if let task = failure.task { lines.append("  task: \(task.rawValue)") }
        if let operation = failure.operation { lines.append("  operation: \(operation)") }
        if let invocation = failure.invocation { lines.append("  command: \(invocation)") }
        if let status = failure.status { lines.append("  status: \(status)") }
        if let signal = failure.signal { lines.append("  signal: \(signal)") }
        if let directory = failure.workingDirectory {
            lines.append("  directory: \(Self.render(path: directory))")
        }
        if let task = failure.task {
            let tail = state.withLock { $0.taskOutputTails[task] ?? [] }
            if !tail.isEmpty {
                lines.append("  output:")
                lines += tail.suffix(8).map { "    \($0)" }
            }
        }
        if let logPath = failure.logPath {
            lines.append("  log: \(Self.render(path: logPath))")
        }
        let message = CredentialScrubber.text(lines.joined(separator: "\n"))
        try human(
            message,
            destination: .standardError,
            style: colorEnabled ? .red : nil)
    }

    /// Record the human names planning gave this run's tasks.
    ///
    /// A lowered SwiftPM invocation is named by the digest of its identity,
    /// which is what makes the name stable across checkouts and what leaves a
    /// reader nothing to read. Planning already knows which component and
    /// product the invocation exists for, so presentation says that and keeps
    /// the digest beside it for correlation. Machine output is unaffected: the
    /// task identity in a JSON progress record or a run manifest is the raw
    /// name, and a label never substitutes for it.
    package func recordTaskLabels(_ labels: [TaskID: String]) {
        guard !labels.isEmpty else { return }
        state.withLock { state in
            state.taskLabels.merge(labels) { _, new in new }
        }
    }

    /// The recorded label for a task, for a caller composing its own line.
    package func displayName(for task: TaskID) -> String {
        state.withLock { Self.displayName(task, labels: $0.taskLabels) }
    }

    package func progress(_ text: String) throws {
        let lines = safeLogicalLines(text)
        try updateProgress(lines, snapshot: nil)
    }

    package func progress(_ snapshot: RunProgressSnapshot) throws {
        let lines = state.withLock { state in
            render(
                snapshot: snapshot,
                latestTaskOutput: state.latestTaskOutput,
                taskLabels: state.taskLabels)
        }
        try updateProgress(lines, snapshot: snapshot)
    }

    package func taskOutput(_ event: TaskOutputEvent) throws {
        try state.withLock { state in
            let result: (lines: [(TaskID?, String)], presentation: TaskOutputPresentation)
            switch event {
            case .chunk(let task, let stream, let bytes, let presentation):
                result = (
                    consumeTaskOutput(
                        bytes,
                        task: task,
                        stream: stream,
                        state: &state),
                    presentation
                )
            case .finished(let task, let presentation):
                result = (finishTaskOutput(task: task, state: &state), presentation)
            }
            guard !result.lines.isEmpty else { return }
            for (task, line) in result.lines {
                guard let task else { continue }
                state.latestTaskOutput[task] = line
                var tail = state.taskOutputTails[task, default: []]
                tail.append(line)
                if tail.count > 20 { tail.removeFirst(tail.count - 20) }
                state.taskOutputTails[task] = tail
            }
            switch result.presentation {
            case .verbose:
                if progressPresentation != .githubActions {
                    refreshSnapshotLines(&state)
                    try writeTaskOutputLines(result.lines, state: &state)
                }
            case .default:
                try refreshSnapshotProgress(&state)
            case .quiet, .raw:
                break
            }
        }
    }

    private func updateProgress(
        _ lines: [String],
        snapshot: RunProgressSnapshot?
    ) throws {
        switch progressPresentation {
        case .disabled:
            return
        case .appendOnly:
            try state.withLock { _ in
                try standardError(Data((lines.joined(separator: "\n") + "\n").utf8))
            }
        case .dynamic:
            try state.withLock { state in
                state.logicalProgressLines = lines
                state.progressSnapshot = snapshot
                try repaint(&state)
            }
        case .githubActions:
            try state.withLock { _ in
                try standardError(Data((lines.joined(separator: "\n") + "\n").utf8))
            }
        case .machine:
            try state.withLock { _ in
                try writeMachineProgress(snapshot)
            }
        }
    }

    package func completeProgress(_ summary: RunTerminalSummary) throws {
        try state.withLock { state in
            try eraseRenderedRegion(&state)
            state.logicalProgressLines = []
            state.progressSnapshot = nil
            state.suspended = false
            try showCursor(&state)
            switch progressPresentation {
            case .machine:
                var bytes = try JSONEncoder.sorted.encode(
                    MachineProgressSummary(kind: "summary", summary: summary))
                bytes.append(0x0A)
                try standardError(bytes)
            case .githubActions:
                let text = safeTerminalText(summary.text) + "\n"
                try standardError(Data(text.utf8))
                for test in summary.failedTestCases {
                    let title = githubCommandProperty("Test \(test.qualifiedName)")
                    let message = githubCommandMessage(
                        "failed in \(safeTerminalText(test.task))")
                    try standardError(
                        Data("::error title=\(title)::\(message)\n".utf8))
                }
                if !state.githubSummaryWritten, let githubStepSummaryPath {
                    try appendGitHubSummary(summary, to: githubStepSummaryPath)
                    state.githubSummaryWritten = true
                }
            case .disabled, .appendOnly, .dynamic:
                let text = safeTerminalText(summary.text) + "\n"
                try standardError(Data(text.utf8))
            }
        }
    }

    package func finishProgress() throws {
        try state.withLock { state in
            try eraseRenderedRegion(&state)
            state.logicalProgressLines = []
            state.progressSnapshot = nil
            state.suspended = false
            try showCursor(&state)
        }
    }

    /// Publish a task's durable output as a collapsible group.
    ///
    /// A stage log exists only once a task writes to it, and plenty of tasks do
    /// real work while saying nothing: publication symlinks, manifest writes,
    /// retention. Opening a group over a log that was never created promises
    /// output the reader will not find, and in a recent sweep fourteen of
    /// twenty-six groups were exactly that. So the group is opened only when
    /// there is something to put in it.
    ///
    /// A failure is the one case where the absence is itself worth reporting:
    /// a container that died before Collider captured anything leaves no log,
    /// and saying so is more useful than saying nothing.
    package func githubTaskLog(
        task: TaskID,
        path: String,
        failed: Bool = false
    ) throws {
        guard progressPresentation == .githubActions else { return }
        let data = try? Data(
            contentsOf: URL(fileURLWithPath: path),
            options: .mappedIfSafe)
        guard let data, !data.isEmpty else {
            guard failed else { return }
            try state.withLock { state in
                let title = githubCommandMessage(
                    Self.qualifiedName(task, labels: state.taskLabels))
                try standardError(Data("::group::\(title)\n".utf8))
                try standardError(
                    Data("stage log unavailable: \(safeTerminalText(path))\n".utf8))
                try standardError(Data("::endgroup::\n".utf8))
            }
            return
        }
        try state.withLock { state in
            let title = githubCommandMessage(
                Self.qualifiedName(task, labels: state.taskLabels))
            try standardError(Data("::group::\(title)\n".utf8))
            let text = safeTerminalText(String(decoding: data, as: UTF8.self))
            for line in text.split(
                separator: "\n",
                omittingEmptySubsequences: false)
            {
                let value = line.hasPrefix("::") ? " \(line)" : String(line)
                try standardError(Data((value + "\n").utf8))
            }
            try standardError(Data("::endgroup::\n".utf8))
        }
    }

    /// Annotate a failed task.
    ///
    /// A resolved diagnostic places the annotation on the source line that
    /// failed, which is where a reader looks first. Without one the annotation
    /// still names the task and its stage log, because a failure with no source
    /// location -- a container that could not start, a validation that rejected
    /// an artifact -- is not attributable to a file.
    package func githubFailure(
        task: TaskID,
        reason: String,
        logPath: String,
        diagnostic: ResolvedSourceDiagnostic? = nil
    ) throws {
        guard progressPresentation == .githubActions else { return }
        try state.withLock { state in
            let title = githubCommandProperty(
                "Collider task "
                    + Self.qualifiedName(task, labels: state.taskLabels))
            if let diagnostic {
                let message = githubCommandMessage(safeTerminalText(diagnostic.message))
                let file = githubCommandProperty(diagnostic.path)
                try standardError(
                    Data(
                        ("::error file=\(file),line=\(diagnostic.line),"
                            + "col=\(diagnostic.column),title=\(title)::\(message)\n").utf8))
            } else {
                let message = githubCommandMessage(
                    "\(safeTerminalText(reason)) (stage log: \(safeTerminalText(logPath)))")
                try standardError(Data("::error title=\(title)::\(message)\n".utf8))
            }
        }
    }

    package func terminalWillInterrupt() throws {
        try finishProgress()
    }

    package func terminalDidResize() throws {
        try state.withLock { state in
            try repaint(&state)
        }
    }

    package func terminalWillSuspend() throws {
        try state.withLock { state in
            try eraseRenderedRegion(&state)
            state.suspended = true
            try showCursor(&state)
        }
    }

    package func terminalDidResume() throws {
        try state.withLock { state in
            state.suspended = false
            try repaint(&state)
        }
    }

    package static func render(command: [String]) -> String {
        CredentialScrubber.renderedCommand(command)
    }

    package static func render(path: String) -> String {
        shellQuoted(CredentialScrubber.text(path))
    }

    private func render(
        snapshot: RunProgressSnapshot,
        latestTaskOutput: [TaskID: String],
        taskLabels: [TaskID: String]
    ) -> [String] {
        var lines: [String]
        if let hostPhase = snapshot.hostPhase {
            let count =
                if let completed = hostPhase.completedItems, let total = hostPhase.totalItems {
                    "  \(completed)/\(total)"
                } else {
                    ""
                }
            lines = [
                "\(hostPhase.name)\(count)  "
                    + Self.renderDuration(snapshot.elapsedNanoseconds)
            ]
        } else {
            switch presentationKind {
            case .taskGraph:
                let percent = Int((snapshot.completionFraction * 100).rounded(.down))
                lines = [
                    "\(snapshot.phase.rawValue)  \(snapshot.completedTaskCount)/"
                        + "\(snapshot.totalTaskCount)  \(percent)%  "
                        + Self.renderDuration(snapshot.elapsedNanoseconds)
                ]
            case .phase:
                lines = [
                    "\(snapshot.phase.rawValue)  "
                        + Self.renderDuration(snapshot.elapsedNanoseconds)
                ]
            case .none:
                lines = []
            }
        }
        lines += snapshot.activeRows.map { row in
            let eventDetail: String =
                switch row.detail {
                case .running: "running"
                case .operation(let operation): operation
                case .waiting(let resource): "waiting for \(resource)"
                case .download(let received, let expected):
                    if let expected {
                        "download \(Self.renderBytes(received))/\(Self.renderBytes(expected))"
                    } else {
                        "download \(Self.renderBytes(received))"
                    }
                }
            let detail = latestTaskOutput[row.task] ?? eventDetail
            let name = Self.displayName(row.task, labels: taskLabels)
            return "\(name) [\(row.lane.rawValue)]  \(detail)"
        }
        if snapshot.residualActiveRowCount > 0 {
            lines.append("+\(snapshot.residualActiveRowCount) more active")
        }
        return lines
    }

    private func consumeTaskOutput(
        _ bytes: [UInt8],
        task: TaskID?,
        stream: TaskOutputStream,
        state: inout State
    ) -> [(TaskID?, String)] {
        let key = TaskOutputBufferKey(task: task, stream: stream)
        var buffer = state.taskOutputBuffers[key, default: []]
        buffer.append(contentsOf: bytes)
        var lines: [(TaskID?, String)] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines += normalizedTaskOutputLine(
                Array(buffer[..<newline]),
                task: task)
            buffer.removeSubrange(...newline)
        }
        if buffer.count > 65_536 {
            buffer.removeFirst(buffer.count - 65_536)
        }
        state.taskOutputBuffers[key] = buffer
        return lines
    }

    private func finishTaskOutput(
        task: TaskID?,
        state: inout State
    ) -> [(TaskID?, String)] {
        let keys = state.taskOutputBuffers.keys.filter { $0.task == task }
        var lines: [(TaskID?, String)] = []
        for key in keys {
            if let bytes = state.taskOutputBuffers.removeValue(forKey: key), !bytes.isEmpty {
                lines += normalizedTaskOutputLine(bytes, task: task)
            }
        }
        return lines
    }

    private func normalizedTaskOutputLine(
        _ bytes: [UInt8],
        task: TaskID?
    ) -> [(TaskID?, String)] {
        safeLogicalLines(String(decoding: bytes, as: UTF8.self)).map {
            (task, $0)
        }
    }

    private func writeTaskOutputLines(
        _ lines: [(TaskID?, String)],
        state: inout State
    ) throws {
        let activeTasks = Set(state.progressSnapshot?.activeRows.map(\.task) ?? [])
        let attributesTasks = activeTasks.count > 1
        try eraseRenderedRegion(&state)
        do {
            for (task, line) in lines {
                let prefix =
                    attributesTasks
                    ? task.map { "\(Self.displayName($0, labels: state.taskLabels)) | " } ?? ""
                    : ""
                try standardError(Data((prefix + line + "\n").utf8))
            }
        } catch {
            try? repaint(&state)
            throw error
        }
        try repaint(&state)
    }

    private func refreshSnapshotProgress(_ state: inout State) throws {
        guard progressPresentation == .dynamic,
            state.progressSnapshot != nil
        else { return }
        refreshSnapshotLines(&state)
        try repaint(&state)
    }

    private func refreshSnapshotLines(_ state: inout State) {
        guard let snapshot = state.progressSnapshot else { return }
        state.logicalProgressLines = render(
            snapshot: snapshot,
            latestTaskOutput: state.latestTaskOutput,
            taskLabels: state.taskLabels)
    }

    /// What a person reads instead of a task's name.
    ///
    /// An unlabelled task is already named for what it does, so it renders as
    /// itself. A labelled one is a lowered SwiftPM invocation whose name is a
    /// digest, and a progress row has to fit a terminal line beside the output
    /// it is reporting, so the row carries the label alone.
    private static func displayName(_ task: TaskID, labels: [TaskID: String]) -> String {
        guard let label = labels[task], !label.isEmpty else { return task.rawValue }
        return truncated(label, to: taskLabelWidth)
    }

    /// What a person reads where the task's identity still has to be recoverable.
    ///
    /// A group title and a failure annotation are both starting points for
    /// looking something up in a run record, which is keyed by the name, so
    /// both keep it. The label leads because that is the half a reader
    /// recognizes and the half that survives when the interface truncates.
    private static func qualifiedName(_ task: TaskID, labels: [TaskID: String]) -> String {
        guard let label = labels[task], !label.isEmpty else { return task.rawValue }
        return "\(truncated(label, to: taskLabelWidth))  (\(task.rawValue))"
    }

    /// One SwiftPM invocation can be merged from more owners than any line can
    /// hold, and the front of that list is the part that identifies it.
    private static let taskLabelWidth = 96

    private static func truncated(_ value: String, to width: Int) -> String {
        guard value.count > width else { return value }
        return value.prefix(width - 1) + "\u{2026}"
    }

    private static func renderDuration(_ nanoseconds: UInt64) -> String {
        let tenths = nanoseconds / 100_000_000
        return "\(tenths / 10).\(tenths % 10)s"
    }

    private static func renderBytes(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        if value >= 1_048_576 {
            return "\(value / 1_048_576) MiB"
        }
        if value >= 1_024 {
            return "\(value / 1_024) KiB"
        }
        return "\(value) B"
    }

    private func writeToStandardOutput(_ data: Data) throws {
        try write(data, destination: .standardOutput)
    }

    private func human(
        _ text: String,
        destination: ConsoleHumanDestination,
        style: Style?
    ) throws {
        var rendered = safeTerminalText(text)
        if !rendered.hasSuffix("\n") { rendered.append("\n") }
        if let style {
            rendered = styled(rendered, style: style)
        }
        try write(Data(rendered.utf8), destination: destination)
    }

    private func write(
        _ data: Data,
        destination: ConsoleHumanDestination
    ) throws {
        try state.withLock { state in
            let regionWasVisible = state.renderedLineCount > 0
            try eraseRenderedRegion(&state)
            do {
                switch destination {
                case .standardOutput:
                    try standardOutput(data)
                    if regionWasVisible, standardOutputIsTerminal, data.last != 0x0A {
                        try standardError(Data("\n".utf8))
                    }
                case .standardError:
                    try standardError(data)
                }
            } catch {
                try? repaint(&state)
                throw error
            }
            try repaint(&state)
        }
    }

    private func repaint(_ state: inout State) throws {
        try eraseRenderedRegion(&state)
        guard !state.suspended, !state.logicalProgressLines.isEmpty else { return }

        let terminal = geometry()
        let lineLimit = min(8, max(0, terminal.rows - 1))
        guard lineLimit > 0 else { return }
        let columnLimit = max(0, terminal.columns - 1)
        let lines = state.logicalProgressLines.suffix(lineLimit).map {
            truncatedToDisplayWidth($0, limit: columnLimit)
        }

        var bytes = Data()
        if !state.cursorHidden {
            bytes.append(Data("\u{001B}[?25l".utf8))
        }
        for (index, line) in lines.enumerated() {
            bytes.append(Data("\r\u{001B}[2K".utf8))
            bytes.append(Data(line.utf8))
            if index + 1 < lines.count {
                bytes.append(0x0A)
            }
        }
        try standardError(bytes)
        state.cursorHidden = true
        state.renderedLineCount = lines.count
    }

    private func eraseRenderedRegion(_ state: inout State) throws {
        guard state.renderedLineCount > 0 else { return }
        var control = "\r\u{001B}[2K"
        for _ in 1..<state.renderedLineCount {
            control += "\u{001B}[1A\r\u{001B}[2K"
        }
        try standardError(Data(control.utf8))
        state.renderedLineCount = 0
    }

    private func showCursor(_ state: inout State) throws {
        guard state.cursorHidden else { return }
        try standardError(Data("\u{001B}[?25h".utf8))
        state.cursorHidden = false
    }

    private func styled(_ text: String, style: Style) -> String {
        guard colorEnabled else { return text }
        let start =
            switch style {
            case .red: "\u{001B}[31m"
            }
        if text.hasSuffix("\n") {
            return start + String(text.dropLast()) + "\u{001B}[0m\n"
        }
        return start + text + "\u{001B}[0m"
    }

    private func writeMachineProgress(_ snapshot: RunProgressSnapshot?) throws {
        guard let snapshot else { return }
        var bytes = try JSONEncoder.sorted.encode(
            MachineProgressSnapshot(kind: "progress", snapshot: snapshot))
        bytes.append(0x0A)
        try standardError(bytes)
    }

    private func appendGitHubSummary(
        _ summary: RunTerminalSummary,
        to path: String
    ) throws {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var markdown =
            "## Collider run `\(githubMarkdownCode(summary.runID))`\n\n"
            + "**Status:** \(summary.status.rawValue)\n\n"
        if !summary.failedTestCases.isEmpty {
            let heading =
                summary.failedTestCaseCount == summary.failedTestCases.count
                ? "### Failed tests"
                : "### Failed tests"
                    + " (\(summary.failedTestCases.count)"
                    + " of \(summary.failedTestCaseCount))"
            markdown += heading + "\n\n"
            markdown += "| Test | Task |\n| --- | --- |\n"
            for test in summary.failedTestCases {
                markdown +=
                    "| `\(githubMarkdownCode(test.qualifiedName))`"
                    + " | `\(githubMarkdownCode(test.task))` |\n"
            }
            markdown += "\n"
        }
        markdown += "```text\n\(safeTerminalText(summary.text))\n```\n\n"
        try handle.write(contentsOf: Data(markdown.utf8))
    }
}

private struct MachineProgressSnapshot: Encodable {
    let kind: String
    let snapshot: RunProgressSnapshot
}

private struct MachineProgressSummary: Encodable {
    let kind: String
    let summary: RunTerminalSummary
}

/// Escape the message half of a workflow command, which is everything after
/// the `::` that closes the property list.
///
/// Only the characters that would end the message or begin another command are
/// escaped. A message is not parsed for properties, so `:` and `,` are ordinary
/// text there; escaping them anyway is what put `%3A` in the middle of every
/// task group title and stage log path CI has produced.
private func githubCommandMessage(_ value: String) -> String {
    value
        .replacingOccurrences(of: "%", with: "%25")
        .replacingOccurrences(of: "\r", with: "%0D")
        .replacingOccurrences(of: "\n", with: "%0A")
}

/// Escape one value in a workflow command's property list, where `,` starts the
/// next property and `:` ends the list.
private func githubCommandProperty(_ value: String) -> String {
    githubCommandMessage(value)
        .replacingOccurrences(of: ":", with: "%3A")
        .replacingOccurrences(of: ",", with: "%2C")
}

private func githubMarkdownCode(_ value: String) -> String {
    safeTerminalText(value).replacingOccurrences(of: "`", with: "\\`")
}

private enum TerminalTextParserState {
    case text
    case escape
    case controlSequence
    case controlString
    case controlStringEscape
}

private func safeLogicalLines(_ text: String) -> [String] {
    safeTerminalText(text).split(
        separator: "\n",
        omittingEmptySubsequences: false
    ).map(String.init)
}

private func safeTerminalText(_ text: String) -> String {
    let scrubbed = CredentialScrubber.text(stripTerminalControls(text))
    return scrubbed
}

private func stripTerminalControls(_ text: String) -> String {
    var result = ""
    var state = TerminalTextParserState.text
    var previousWasCarriageReturn = false

    for scalar in text.unicodeScalars {
        let value = scalar.value
        switch state {
        case .text:
            switch value {
            case 0x1B:
                state = .escape
                previousWasCarriageReturn = false
            case 0x9B:
                state = .controlSequence
                previousWasCarriageReturn = false
            case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
                state = .controlString
                previousWasCarriageReturn = false
            case 0x0D:
                result.append("\n")
                previousWasCarriageReturn = true
            case 0x0A:
                if !previousWasCarriageReturn { result.append("\n") }
                previousWasCarriageReturn = false
            case 0x09:
                result.append("    ")
                previousWasCarriageReturn = false
            case 0x00...0x1F, 0x7F...0x9F:
                previousWasCarriageReturn = false
            default:
                result.unicodeScalars.append(scalar)
                previousWasCarriageReturn = false
            }
        case .escape:
            switch value {
            case 0x5B:
                state = .controlSequence
            case 0x50, 0x58, 0x5D, 0x5E, 0x5F:
                state = .controlString
            default:
                state = .text
            }
        case .controlSequence:
            if (0x40...0x7E).contains(value) { state = .text }
        case .controlString:
            if value == 0x07 {
                state = .text
            } else if value == 0x1B {
                state = .controlStringEscape
            }
        case .controlStringEscape:
            state = value == 0x5C ? .text : .controlString
        }
    }
    return result
}

private func truncatedToDisplayWidth(_ text: String, limit: Int) -> String {
    guard limit > 0 else { return "" }
    var result = ""
    var width = 0
    for character in text {
        let characterWidth = terminalDisplayWidth(of: character)
        guard width + characterWidth <= limit else { break }
        result.append(character)
        width += characterWidth
    }
    return result
}

private func terminalDisplayWidth(of character: Character) -> Int {
    let scalars = character.unicodeScalars
    if scalars.contains(where: {
        $0.value == 0x200D || $0.value == 0xFE0F || $0.properties.isEmojiPresentation
    }) {
        return 2
    }
    return scalars.reduce(into: 0) { width, scalar in
        width += terminalDisplayWidth(of: scalar)
    }
}

private func scrubbedJSON<Value: Encodable>(_ value: Value) throws -> Data {
    let encoded = try JSONEncoder.sorted.encode(value)
    let object = try JSONSerialization.jsonObject(
        with: encoded,
        options: [.fragmentsAllowed])
    return try JSONSerialization.data(
        withJSONObject: scrubJSONValue(object),
        options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
}

private func scrubJSONValue(_ value: Any) -> Any {
    switch value {
    case let string as String:
        CredentialScrubber.text(string)
    case let array as [Any]:
        array.map(scrubJSONValue)
    case let dictionary as [String: Any]:
        dictionary.mapValues(scrubJSONValue)
    default:
        value
    }
}

private func shellQuoted(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    let safe = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "_@%+=:,./-"))
    if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
