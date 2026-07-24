import ChromiumColliderRecipe
import ColliderCore
import Foundation
import SystemPackage
import Testing
@testable import ColliderCommands

@Test
func chromiumCommandHasOneOpinionatedOperationSurface() throws {
    #expect(!(try Browser.Bootstrap.parse([])).taskOptions.dryRun)
    #expect(
        try Browser.Build.parse(["--dry-run"]).taskOptions.dryRun)
    #expect(
        try Browser.Test.parse(["--explain"]).taskOptions.explain)
    #expect(
        try Install.Browser.parse(["--prefix", "/browser"]).prefix
            == "/browser")

    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["browser", "build", "cef"])
    }
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["browser", "package-only"])
    }
}

@Test
func chromiumSourceIdentityMatchesThePinnedMetadataContract() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let command = ChromiumCommand(context: WorkspaceContext(
        root: root,
        environment: ProcessInfo.processInfo.environment))
    let sourceIdentifier = try command.sourceIdentifier()
    #expect(sourceIdentifier == "dd3aa8d9a86e2424505eaf23")
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
