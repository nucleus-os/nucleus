import ArgumentParser
import ColliderCore
import Testing

@testable import ColliderCLI
@testable import ColliderWorkspaceCommands

private let taskControlledLeaves: [[String]] = [
    ["bootstrap"],
    ["build"],
    ["test"],
    ["generate", "vulkan"],
    ["generate", "wayland"],
    ["swift-sdk", "rebuild"],
    ["android", "build"],
    ["android", "native"],
    ["android", "verify"],
    ["android-runtime", "source-lock"],
    ["android-runtime", "source"],
    ["android-runtime", "image"],
    ["browser", "bootstrap"],
    ["browser", "build"],
    ["browser", "test"],
    ["install", "browser"],
    ["sanitize"],
    ["benchmark"],
]

private let reportLeaves: [[String]] = [
    ["status"],
    ["logs", "list"],
    ["cache", "status"],
    ["swift-sdk", "status"],
]

private let diagnosticLeaves: [[String]] = [
    ["doctor"],
    ["browser", "doctor"],
    ["clean", "core"],
    ["cache", "prune"],
]

private let controlFreeLeaves: [[String]] = [
    ["logs", "show"],
    ["logs", "tail"],
]

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
    for path in reportLeaves + controlFreeLeaves {
        let parsed = try ColliderCommand.parseAsRoot(
            path + ["--format", "json", "--color", "always", "--progress", "never"])
        let command = try #require(parsed as? any OutputConfiguredCommand)
        #expect(command.outputOptions.format == .json)
        #expect(command.outputOptions.color == .always)
        #expect(command.outputOptions.progress == .never)
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
func installationAndBrowserHelpExposeOneBrowserInstallLeaf() throws {
    _ = try ColliderCommand.parseAsRoot(["install", "browser"])
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["browser", "install"])
    }

    let installHelp = ColliderCommand.message(
        for: CleanExit.helpRequest(Install.self))
    let browserHelp = ColliderCommand.message(
        for: CleanExit.helpRequest(Browser.self))
    #expect(installHelp.contains("browser"))
    #expect(!browserHelp.contains("install"))
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
        if ["--run-id", "--format", "--color", "--progress"].contains(options[index]) {
            result.append([options[index], options[index + 1]])
            index += 2
        } else {
            result.append([options[index]])
            index += 1
        }
    }
    return result
}
