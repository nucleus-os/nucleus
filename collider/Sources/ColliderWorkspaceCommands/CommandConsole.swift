import ColliderCore
import Foundation
import Synchronization

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

package enum ConsoleProgressPresentation: Equatable, Sendable {
    case disabled
    case appendOnly
    case dynamic
}

package enum ConsoleHumanDestination: Sendable {
    case standardOutput
    case standardError
}

package final class CommandConsole: @unchecked Sendable {
    package typealias Writer = @Sendable (Data) throws -> Void

    package let format: ConsoleOutputFormat
    package let colorEnabled: Bool
    package let progressPresentation: ConsoleProgressPresentation

    private struct State {
        var dynamicProgressActive = false
    }

    private let standardOutput: Writer
    private let standardError: Writer
    private let state = Mutex(State())

    package init(
        format: ConsoleOutputFormat = .text,
        color: ConsoleColorPolicy = .auto,
        progress: ConsoleProgressPolicy = .auto,
        standardOutputIsTerminal: Bool = false,
        standardErrorIsTerminal: Bool = false,
        environment: [String: String] = [:],
        standardOutput: @escaping Writer,
        standardError: @escaping Writer
    ) {
        self.format = format
        colorEnabled =
            switch color {
            case .auto: standardErrorIsTerminal && environment["NO_COLOR"] == nil
            case .always: environment["NO_COLOR"] == nil
            case .never: false
            }
        progressPresentation =
            switch progress {
            case .never: .disabled
            case .auto: standardErrorIsTerminal ? .dynamic : .appendOnly
            case .always: standardErrorIsTerminal ? .dynamic : .appendOnly
            }
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    package static func process(
        options: CommandOutputOptions,
        environment: [String: String],
        standardOutputIsTerminal: Bool,
        standardErrorIsTerminal: Bool
    ) -> CommandConsole {
        CommandConsole(
            format: options.format,
            color: options.color,
            progress: options.progress,
            standardOutputIsTerminal: standardOutputIsTerminal,
            standardErrorIsTerminal: standardErrorIsTerminal,
            environment: environment,
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
        try finishProgress()
        var rendered = text
        if !rendered.hasSuffix("\n") { rendered.append("\n") }
        let bytes = Data(CredentialScrubber.bytes(Array(rendered.utf8)))
        switch destination {
        case .standardOutput: try standardOutput(bytes)
        case .standardError: try standardError(bytes)
        }
    }

    package func rawReport(_ text: String) throws {
        try finishProgress()
        try standardOutput(Data(CredentialScrubber.bytes(Array(text.utf8))))
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
        if let logPath = failure.logPath {
            lines.append("  log: \(Self.render(path: logPath))")
        }
        let message = CredentialScrubber.text(lines.joined(separator: "\n"))
        if colorEnabled {
            try human("\u{001B}[31m\(message)\u{001B}[0m", destination: .standardError)
        } else {
            try human(message, destination: .standardError)
        }
    }

    package func progress(_ text: String) throws {
        let scrubbed = CredentialScrubber.text(text)
        switch progressPresentation {
        case .disabled:
            return
        case .appendOnly:
            try standardError(Data((scrubbed + "\n").utf8))
        case .dynamic:
            state.withLock { $0.dynamicProgressActive = true }
            try standardError(Data(("\r\u{001B}[2K" + scrubbed).utf8))
        }
    }

    package func finishProgress() throws {
        let wasActive = state.withLock { state in
            let active = state.dynamicProgressActive
            state.dynamicProgressActive = false
            return active
        }
        if wasActive { try standardError(Data("\r\u{001B}[2K".utf8)) }
    }

    package static func render(command: [String]) -> String {
        CredentialScrubber.renderedCommand(command)
    }

    package static func render(path: String) -> String {
        shellQuoted(CredentialScrubber.text(path))
    }

    private func writeToStandardOutput(_ data: Data) throws {
        try finishProgress()
        try standardOutput(data)
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
