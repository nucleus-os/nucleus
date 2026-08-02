import ArgumentParser
import ColliderCore
import Testing

@testable import ColliderCommands

#if os(Linux)
import NucleusAndroidRuntimeCore
#endif

private let taskControlledLeaves: [[String]] = [
    ["bootstrap"],
    ["build"],
    ["test"],
    ["generate", "rn-spec"],
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
    ["validate", "vulkan"],
    ["cache", "prune"],
]

private let controlFreeLeaves: [[String]] = {
    var leaves = [
        ["sanitize"],
        ["benchmark"],
        ["logs", "show"],
        ["logs", "tail"],
    ]
    #if os(Linux)
    leaves += [["run"], ["install", "session"]]
    #endif
    return leaves
}()

@Test
func everyTaskControlledLeafParsesTheCompleteControlSet() throws {
    for path in taskControlledLeaves {
        let parsed = try ColliderCommand.parseAsRoot(
            path + [
                "--dry-run",
                "--explain",
                "--verbose",
                "--json",
                "--run-id", "run-capability-test",
            ])
        let command = try #require(parsed as? any TaskControlledCommand)
        #expect(command.taskOptions.dryRun)
        #expect(command.taskOptions.explain)
        #expect(command.taskOptions.verbose)
        #expect(!command.taskOptions.quiet)
        #expect(command.taskOptions.json)
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
        _ = try ColliderCommand.parseAsRoot(path + ["--json"])
        awaitRejects(
            path,
            options: [
                "--dry-run",
                "--explain",
                "--verbose",
                "--quiet",
                "--run-id", "not-supported",
            ])
    }

    for path in diagnosticLeaves {
        _ = try ColliderCommand.parseAsRoot(
            path + ["--dry-run", "--json"])
        awaitRejects(
            path,
            options: [
                "--explain",
                "--verbose",
                "--quiet",
                "--run-id", "not-supported",
            ])
    }

    for path in controlFreeLeaves {
        awaitRejects(
            path,
            options: [
                "--dry-run",
                "--explain",
                "--verbose",
                "--quiet",
                "--json",
                "--run-id", "not-supported",
            ])
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

#if os(Linux)
@Test
func privilegedAndroidOperationsStayOutOfColliderRootHelp() {
    let rootHelp = ColliderCommand.message(for: CleanExit.helpRequest())
    #expect(
        !rootHelp.contains(
            AndroidRuntimePrivilegedOperation.apexMountCommandName))
    #expect(
        !rootHelp.contains(
            AndroidRuntimePrivilegedOperation.bpfBrokerCommandName))
    #expect(
        !rootHelp.contains(
            AndroidRuntimePrivilegedOperation.bpfMountCommandName))
    #expect(
        !rootHelp.contains(
            AndroidRuntimePrivilegedOperation.cgroupDelegateCommandName))
}
#endif

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
        if options[index] == "--run-id" {
            result.append([options[index], options[index + 1]])
            index += 2
        } else {
            result.append([options[index]])
            index += 1
        }
    }
    return result
}
