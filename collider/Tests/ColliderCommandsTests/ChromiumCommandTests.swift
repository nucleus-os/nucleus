import ChromiumColliderRecipe
import ColliderCore
import Foundation
import SystemPackage
import Testing
@testable import ColliderCommands

@Test
func chromiumCommandHasOneOpinionatedOperationSurface() throws {
    #expect(try ChromiumCommand.parse(["doctor"]) == .doctor)
    #expect(try ChromiumCommand.parse(["bootstrap"]) == .bootstrap)
    #expect(try ChromiumCommand.parse(["build"]) == .build)
    #expect(try ChromiumCommand.parse(["test"]) == .test)
    #expect(try ChromiumCommand.parse(["install"]) == .install)

    #expect(throws: WorkspaceFailure.self) {
        try ChromiumCommand.parse(["build", "cef"])
    }
    #expect(throws: WorkspaceFailure.self) {
        try ChromiumCommand.parse(["package-only"])
    }
}

@Test
func chromiumSourceIdentityMatchesThePinnedMetadataContract() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let command = ChromiumCommand(context: WorkspaceContext(
        root: root,
        environment: ProcessInfo.processInfo.environment))
    #expect(try command.sourceIdentifier() == "bfa128bb14bb2397ef19b426")
}

@Test
func chromiumRecipeOwnsTheOrderedCefAndBrowserGraph() throws {
    let root = FilePath("/workspace")
    let tasks = try ChromiumColliderRecipe.tasks(
        workspaceRoot: root,
        environment: ["PATH": "/usr/bin"],
        layout: ChromiumRecipeLayout(
            sourceID: "source-identity",
            cacheRoot: FilePath("/cache/cef"),
            installPrefix: FilePath("/home/user/.local"),
            jobs: 16))
    let graph = try TaskGraph(tasks)
    #expect(try graph.orderedTasks(selecting: [
        TaskID(rawValue: "browser.retention"),
    ]).map(\.id.rawValue) == [
        "browser.depot-tools",
        "browser.depot-tools-bootstrap",
        "browser.cef-automation",
        "browser.source",
        "browser.cef",
        "browser.artifact",
        "browser.retention",
    ])

    func commands(_ operation: TaskOperation) -> [CommandSpec] {
        switch operation {
        case .command(let command): [command]
        case .sequence(let operations):
            operations.flatMap(commands)
        default: []
        }
    }
    #expect(tasks.flatMap { commands($0.operation) }.allSatisfy {
        if case .path(let path) = $0.executable {
            return path != root.appending("chromium/build.sh")
        }
        return true
    })
}
