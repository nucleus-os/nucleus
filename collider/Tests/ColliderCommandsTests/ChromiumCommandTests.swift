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
    #expect(
        Set(tasks.map(\.id)).isSuperset(of: [
            ChromiumTaskIDs.source,
            ChromiumTaskIDs.retention,
            ChromiumTaskIDs.test,
            ChromiumTaskIDs.install,
        ]))
    #expect(
        try graph.orderedTasks(selecting: [
            ChromiumTaskIDs.retention
        ]).map(\.id.rawValue) == [
            "browser.depot-tools",
            "browser.depot-tools-bootstrap",
            "browser.source",
            "browser.builder",
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
    #expect(
        tasks.flatMap { commands($0.operation) }.allSatisfy {
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
    #expect(
        products.allSatisfy {
            $0.gnArguments?.contains(#"ffmpeg_branding="Chrome""#) == true
                && $0.gnArguments?.contains(#"ozone_platform="wayland""#) == true
        })
    let cef = try #require(products.first { $0.product == .cef })
    #expect(cef.output == FilePath("/cache/cef/build/source-identity/cef"))
    #expect(
        cef.containerImageID
            == FilePath("/cache/cef/build-container/image-id"))
    #expect(cef.gnArguments?.contains("enable_widevine=true") == true)
    #expect(cef.gnArguments?.contains("use_allocator_shim=false") == true)
    #expect(
        cef.gnArguments?.contains("use_partition_alloc_as_malloc=false")
            == true)

    let test = try #require(
        tasks.first { $0.id == ChromiumTaskIDs.test })
    guard case .sequence(let testOperations) = test.operation,
        case .runOCI(let execution) = testOperations.first
    else {
        Issue.record("Chromium test compilation must use the builder")
        return
    }
    #expect(execution.command.first == "build")
    #expect(
        execution.mounts == [
            OCIMount(
                source: FilePath(
                    "/cache/cef/source-generations/source-identity"),
                target: "/source",
                access: .readOnly),
            OCIMount(
                source: FilePath("/cache/cef/depot_tools"),
                target: "/depot_tools",
                access: .readOnly),
            OCIMount(
                source: FilePath(
                    "/cache/cef/build/source-identity/.inputs"),
                target: "/inputs",
                access: .readOnly),
            OCIMount(
                source: FilePath(
                    "/cache/cef/build/source-identity/browser"),
                target: "/build",
                access: .readWrite),
        ])
}
