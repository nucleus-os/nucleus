import ArgumentParser
import ColliderCore
import Foundation
import Testing

@testable import ColliderCLI
@testable import ColliderWorkspaceCommands

private let taskControlledLeaves: [[String]] = [
    ["bootstrap"],
    ["build"],
    ["test"],
    ["check", "sanitizers"],
    ["check", "address-sanitizer"],
    ["check", "undefined-behavior-sanitizer"],
    ["check", "thread-sanitizer"],
    ["check", "android-source-lock"],
    ["check", "protected-main-source"],
    ["generate", "vulkan"],
    ["package", "linux-runtime"],
    ["benchmark"],
]

private let reportLeaves: [[String]] = [
    ["status"],
    ["status", "swift-sdk"],
    ["logs", "list"],
    ["logs", "path"],
    ["runs", "list"],
    ["runs", "show"],
    ["tasks"],
    ["graph", "build", "all"],
    ["cache", "status"],
]

private let phaseReportLeaves: [[String]] = [
    ["cache", "status"]
]

private let diagnosticLeaves: [[String]] = [
    ["doctor"],
    ["doctor", "browser"],
    ["clean", "core"],
    ["cache", "prune"],
]

private let controlFreeLeaves: [[String]] = [
    ["logs", "tail"]
]

@Test func commandClassesProvidePresentationWithoutLeafOptIn() throws {
    for path in taskControlledLeaves {
        let command = try #require(
            try ColliderCommand.parseAsRoot(path) as? any ColliderWorkspaceCommand)
        #expect(command.presentationKind == .taskGraph)
    }
    for path in reportLeaves.filter({ !phaseReportLeaves.contains($0) }) + controlFreeLeaves {
        let command = try #require(
            try ColliderCommand.parseAsRoot(path) as? any ColliderWorkspaceCommand)
        #expect(command.presentationKind == .none)
    }
    for path in diagnosticLeaves + phaseReportLeaves {
        let command = try #require(
            try ColliderCommand.parseAsRoot(path) as? any ColliderWorkspaceCommand)
        #expect(command.presentationKind == .phase)
    }
}

@Test
func everyTaskControlledLeafParsesTheCompleteControlSet() throws {
    for path in taskControlledLeaves {
        let parsed = try ColliderCommand.parseAsRoot(
            path + [
                "--dry-run",
                "--rebuild",
                "--verbose",
                "--format", "json",
                "--color", "never",
                "--progress", "never",
                "--progress-format", "json",
                "--run-id", "run-capability-test",
            ])
        let command = try #require(parsed as? any TaskControlledCommand)
        #expect(command.taskOptions.dryRun)
        #expect(command.taskOptions.rebuild)
        #expect(command.taskOptions.verbose)
        #expect(!command.taskOptions.quiet)
        #expect(command.outputOptions.format == .json)
        #expect(command.outputOptions.color == .never)
        #expect(command.outputOptions.progress == .never)
        #expect(command.outputOptions.progressFormat == .json)
        #expect(
            command.taskOptions.runID?.value
                == RunID(rawValue: "run-capability-test"))
        #expect(
            requestedRunID(for: parsed)
                == RunID(rawValue: "run-capability-test"))
    }
}

@Test
func taskControlledLeavesAcceptQuietOutput() throws {
    for path in taskControlledLeaves {
        let parsed = try ColliderCommand.parseAsRoot(path + ["--quiet"])
        let command = try #require(parsed as? any TaskControlledCommand)
        #expect(command.taskOptions.quiet)
    }
}

/// The options the privileged launcher admits, read from the launcher itself.
///
/// The launcher runs under a password-free sudo grant, so it validates every
/// option independently rather than trusting the process that invoked it. That
/// makes it a third grammar rather than a restatement of the second, and the
/// only one whose refusal is invisible until someone runs the command on a host
/// that has a build store. It cannot be asked what it admits, because it
/// requires root before it parses anything, so its list is read where written.
private let launcherAdmittedOptions: Set<String> = {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/macos-builder/nucleus-builder-run")
    guard let contents = try? String(contentsOf: script, encoding: .utf8) else {
        return []
    }
    var options: Set<String> = []
    for line in contents.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A case label naming one or more options, and nothing else.
        guard trimmed.hasSuffix(")"), trimmed.hasPrefix("--") else { continue }
        for candidate in trimmed.dropLast().split(separator: "|") {
            let name = candidate.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix("--") else { continue }
            options.insert(name)
        }
    }
    return options
}()

/// Reading the launcher must actually have found something. An empty parse
/// would make the agreement check vacuously true, which is the failure mode
/// this test exists to prevent.
@Test func theLauncherAndTheCrossingAdmitTheSameOptions() throws {
    #expect(launcherAdmittedOptions.count >= 10)
    let crossing = Set(BuilderElevation.admittedOptions.keys)
    let launcherOnly = launcherAdmittedOptions.subtracting(crossing).sorted()
    let crossingOnly = crossing.subtracting(launcherAdmittedOptions).sorted()
    let message: String =
        "launcher alone: \(launcherOnly); crossing alone: \(crossingOnly)"
    #expect(
        launcherAdmittedOptions == crossing,
        Comment(rawValue: message))
}

/// The options a command accepts and the options the builder crossing admits
/// are two grammars that have to agree.
///
/// On a host with a machine build store, a command that executes a task graph
/// re-runs itself as the builder, and the launcher refuses an option it does
/// not list rather than dropping it. An option added to the command surface
/// alone therefore parses everywhere and fails only on the machine that has a
/// build store, which is the machine that matters.
@Test func everyControlOnACrossingCommandIsAdmittedByTheLauncher() throws {
    let exempt: Set<String> = ["--help", "--version"]
    for path in taskControlledLeaves {
        let parsed = try ColliderCommand.parseAsRoot(path)
        let help = ColliderCommand.helpMessage(
            for: type(of: parsed),
            columns: 400)
        for line in help.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("  ") else { continue }
            let trimmed = line.drop(while: { $0 == " " })
            guard trimmed.hasPrefix("--") else { continue }
            let name = String(
                trimmed.prefix(while: { $0 == "-" || $0.isLetter || $0.isNumber }))
            guard !exempt.contains(name) else { continue }
            let described = path.joined(separator: " ")
            guard let carriesValue = BuilderElevation.admittedOptions[name] else {
                Issue.record("'\(described)' accepts \(name), which the builder crossing refuses")
                continue
            }
            let refused: String =
                "'\(described)' accepts \(name), which the privileged launcher "
                + "does not admit; it fails only on a host with a build store"
            #expect(
                launcherAdmittedOptions.contains(name),
                Comment(rawValue: refused))
            // Arity has to agree too. An option admitted as a flag that really
            // takes a value leaves the value behind as a command word, which
            // reaches the builder as a selection nobody asked for.
            let declaresValue = trimmed.dropFirst(name.count).hasPrefix(" <")
            let declared: String = declaresValue ? "with" : "without"
            let admitted: String = carriesValue ? "with" : "without"
            let arity: String =
                "'\(described)' declares \(name) \(declared) a value; the "
                + "builder crossing admits it \(admitted) one"
            #expect(carriesValue == declaresValue, Comment(rawValue: arity))
        }
    }
}

@Test
func removedExplainControlIsRejected() {
    for path in taskControlledLeaves {
        #expect(throws: (any Error).self) {
            try ColliderCommand.parseAsRoot(path + ["--explain"])
        }
    }
}

@Test
func quietAndVerboseTaskOutputAreMutuallyExclusive() {
    for path in taskControlledLeaves {
        #expect(throws: (any Error).self) {
            try ColliderCommand.parseAsRoot(path + ["--quiet", "--verbose"])
        }
    }
}

@Test
func nonTaskLeavesExposeOnlyTheirDeclaredControls() throws {
    for path in reportLeaves {
        let parsed = try ColliderCommand.parseAsRoot(
            path + [
                "--format", "json", "--color", "always", "--progress", "never",
                "--progress-format", "json",
            ])
        let command = try #require(parsed as? any OutputConfiguredCommand)
        #expect(command.outputOptions.format == .json)
        #expect(command.outputOptions.color == .always)
        #expect(command.outputOptions.progress == .never)
        #expect(command.outputOptions.progressFormat == .json)
        awaitRejects(
            path,
            options: [
                "--dry-run",
                "--rebuild",
                "--verbose",
                "--quiet",
                "--run-id", "not-supported",
            ])
    }

    for path in controlFreeLeaves {
        _ = try ColliderCommand.parseAsRoot(
            path + ["--format", "text", "--color", "always", "--progress", "never"])
        awaitRejects(
            path,
            options: [
                "--format", "json",
                "--dry-run",
                "--rebuild",
                "--verbose",
                "--quiet",
                "--run-id", "not-supported",
            ])
    }

    for path in diagnosticLeaves {
        _ = try ColliderCommand.parseAsRoot(
            path + ["--dry-run", "--format", "json"])
        awaitRejects(
            path,
            options: [
                "--rebuild",
                "--verbose",
                "--quiet",
                "--run-id", "not-supported",
            ])
    }

    for path in taskControlledLeaves + reportLeaves + diagnosticLeaves + controlFreeLeaves {
        #expect(throws: (any Error).self) {
            try ColliderCommand.parseAsRoot(path + ["--json"])
        }
    }
}

@Test
func browserInstallationGrammarIsRemoved() throws {
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["install", "browser"])
    }
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["browser", "install"])
    }
}

private func awaitRejects(_ path: [String], options: [String]) {
    for option in optionInvocations(options) {
        #expect(throws: (any Error).self) {
            try ColliderCommand.parseAsRoot(path + option)
        }
    }
}

private func optionInvocations(_ options: [String]) -> [[String]] {
    var result: [[String]] = []
    var index = options.startIndex
    while index < options.endIndex {
        if ["--run-id", "--format", "--color", "--progress", "--progress-format"].contains(
            options[index])
        {
            result.append([options[index], options[index + 1]])
            index += 2
        } else {
            result.append([options[index]])
            index += 1
        }
    }
    return result
}
