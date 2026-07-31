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
    #expect(sourceIdentifier == "bb787197253f6bcc61903a0b")
}

@Test
func chromiumRecipeOwnsTheOrderedCefAndBrowserGraph() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let workspace = FilePath(root.path)
    let tasks = try ChromiumColliderRecipe.tasks(
        workspaceRoot: workspace,
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
            return path != workspace.appending("chromium/build.sh")
        }
        return true
    })

    func builds(_ operation: TaskOperation) -> [ChromiumProductBuild] {
        switch operation {
        case .buildChromiumProduct(let build): [build]
        case .sequence(let operations):
            operations.flatMap(builds)
        default: []
        }
    }
    let products = tasks.flatMap { builds($0.operation) }
    #expect(products.count == 2)
    #expect(products.allSatisfy {
        $0.gnArguments?.contains(#"ffmpeg_branding="Chrome""#) == true
            && $0.gnArguments?.contains(#"ozone_platform="wayland""#) == true
    })
    let cef = try #require(products.first { $0.product == .cef })
    #expect(cef.gnArguments?.contains("enable_widevine=true") == true)
    #expect(cef.gnArguments?.contains("use_allocator_shim=false") == true)
    #expect(
        cef.gnArguments?.contains("use_partition_alloc_as_malloc=false")
            == true)
}
