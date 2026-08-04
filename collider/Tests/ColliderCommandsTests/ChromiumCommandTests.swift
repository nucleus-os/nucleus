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
func chromiumRecipeOwnsTheOrderedCefAndBrowserGraph() async throws {
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

    func actions(_ operation: TaskOperation) -> [AnyColliderAction] {
        switch operation {
        case .action(let action): [action]
        case .sequence(let operations):
            operations.flatMap(actions)
        default: []
        }
    }
    #expect(
        Set(tasks.flatMap { actions($0.operation).map(\.kind) }).isSuperset(of: [
            ActionKind(rawValue: "browser.bootstrap-depot-tools"),
            ActionKind(rawValue: "browser.test-ozone"),
        ]))

    let productActions = tasks.flatMap {
        actions($0.operation)
    }.filter { $0.kind == ActionKind(rawValue: "browser.build-product") }
    #expect(productActions.count == 2)
    #expect(Set(productActions.map(\.identity)).count == 2)
    #expect(
        productActions.allSatisfy {
            $0.requirements.executionPlatform == .linuxAMD64OCI
                && $0.requirements.artifactTarget == .linuxX86_64
                && $0.requirements.resources.exclusive
        })

    let test = try #require(
        tasks.first { $0.id == ChromiumTaskIDs.test })
    guard case .sequence = test.operation,
        let execution = try await ociExecutions(in: test.operation).first
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
