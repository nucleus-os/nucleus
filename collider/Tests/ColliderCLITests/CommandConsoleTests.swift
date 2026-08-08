import ColliderCore
import Foundation
import Testing

@testable import ColliderWorkspaceCommands

private final class ConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func write(_ data: Data) {
        lock.withLock { storage.append(data) }
    }

    var text: String {
        lock.withLock { String(decoding: storage, as: UTF8.self) }
    }
}

private struct FixtureReport: Codable, Equatable {
    let value: String
}

@Test func jsonReportWritesOneValueToStandardOutput() throws {
    let standardOutput = ConsoleCapture()
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        format: .json,
        color: .never,
        progress: .never,
        standardOutput: standardOutput.write,
        standardError: standardError.write)

    try console.report(FixtureReport(value: "fixture"), text: "human fixture")

    #expect(standardOutput.text == #"{"value":"fixture"}"# + "\n")
    #expect(standardError.text.isEmpty)
}

@Test func jsonReportScrubsCredentialValuesWithoutBreakingThePayload() throws {
    let standardOutput = ConsoleCapture()
    let console = CommandConsole(
        format: .json,
        standardOutput: standardOutput.write,
        standardError: { _ in })

    try console.report(
        FixtureReport(value: "token=secret"),
        text: "unused")

    let decoded = try JSONDecoder().decode(
        FixtureReport.self,
        from: Data(standardOutput.text.utf8))
    #expect(decoded == FixtureReport(value: "token=<redacted>"))
}

@Test func humanDiagnosticsUseOnlyStandardError() throws {
    let standardOutput = ConsoleCapture()
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        standardOutput: standardOutput.write,
        standardError: standardError.write)

    try console.diagnostic("diagnostic")

    #expect(standardOutput.text.isEmpty)
    #expect(standardError.text == "diagnostic\n")
}

@Test func redirectedProgressIsAppendOnlyWithoutCursorControl() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .always,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress("first")
    try console.progress("second")
    try console.finishProgress()

    #expect(console.progressPresentation == .appendOnly)
    #expect(standardError.text == "first\nsecond\n")
    #expect(!standardError.text.contains("\u{001B}"))
}

@Test func dynamicProgressRestoresTheTerminalBeforeDiagnostics() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        progress: .auto,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.progress("working")
    try console.diagnostic("failed")

    #expect(console.progressPresentation == .dynamic)
    #expect(standardError.text.hasSuffix("\r\u{001B}[2Kfailed\n"))
}

@Test func colorPolicyHonorsTerminalCapabilityAndNoColor() {
    let automatic = CommandConsole(
        color: .auto,
        standardErrorIsTerminal: true,
        standardOutput: { _ in },
        standardError: { _ in })
    let redirected = CommandConsole(
        color: .auto,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: { _ in })
    let disabledByEnvironment = CommandConsole(
        color: .always,
        standardErrorIsTerminal: true,
        environment: ["NO_COLOR": "1"],
        standardOutput: { _ in },
        standardError: { _ in })

    #expect(automatic.colorEnabled)
    #expect(!redirected.colorEnabled)
    #expect(!disabledByEnvironment.colorEnabled)
}

@Test func commandRenderingQuotesArgumentsAndScrubsCredentials() {
    let rendered = CommandConsole.render(command: [
        "tool", "--token", "secret value", "path with spaces",
    ])

    #expect(rendered == "tool --token '<redacted>' 'path with spaces'")
    #expect(!rendered.contains("secret value"))
}

@Test func failureRenderingUsesColorOnlyWhenEnabledAndScrubsCredentials() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        color: .always,
        standardErrorIsTerminal: false,
        standardOutput: { _ in },
        standardError: standardError.write)

    try console.failure(FixtureFailure("token=secret"))

    #expect(standardError.text.contains("\u{001B}[31m"))
    #expect(standardError.text.contains("token=<redacted>"))
    #expect(!standardError.text.contains("token=secret"))
}

@Test func structuredFailureRenderingUsesFieldsWithoutParsingItsDescription() throws {
    let standardError = ConsoleCapture()
    let console = CommandConsole(
        color: .never,
        standardOutput: { _ in },
        standardError: standardError.write)
    let failure = ExecutionFailure(
        task: TaskID(rawValue: "fixture.build"),
        operation: "swift build",
        command: ["swift", "build"],
        status: 137,
        signal: 9,
        invocation: "swift build",
        workingDirectory: "/workspace with spaces",
        logPath: "/runs/fixture/stages/fixture-build.log",
        reason: "child command failed")

    try console.failure(failure)

    #expect(standardError.text.contains("task: fixture.build"))
    #expect(standardError.text.contains("operation: swift build"))
    #expect(standardError.text.contains("command: swift build"))
    #expect(standardError.text.contains("status: 137"))
    #expect(standardError.text.contains("signal: 9"))
    #expect(standardError.text.contains("directory: '/workspace with spaces'"))
    #expect(standardError.text.contains("log: /runs/fixture/stages/fixture-build.log"))
}

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
