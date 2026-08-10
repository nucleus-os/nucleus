import ChromiumColliderRecipe
import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

@Test
func chromiumCommandHasOneOpinionatedOperationSurface() throws {
    #expect((try Bootstrap.parse(["browser"])).component == "browser")
    #expect(
        try Build.parse(["browser", "--dry-run"]).taskOptions.dryRun)
    #expect(
        try Test.parse(["browser", "--verbose"]).taskOptions.verbose)
    #expect(
        try InstallBrowser.parse(["--prefix", "/browser"]).prefix
            == "/browser")
}

@Test
func chromiumRecipeOwnsTheTypedConcurrentCefAndBrowserGraph() async throws {
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
        Set(tasks.map(\.id)).isSuperset(
            of: [
                ChromiumTaskIDs.source,
                ChromiumTaskIDs.retention,
                ChromiumTaskIDs.install,
            ] + chromiumLinuxTargets.map(ChromiumTaskIDs.test)))
    let orderedBuildTasks = try graph.orderedTasks(selecting: [
        ChromiumTaskIDs.retention
    ]).map(\.id)
    #expect(orderedBuildTasks.count == 13)
    #expect(orderedBuildTasks.last == ChromiumTaskIDs.retention)

    #expect(
        Set(tasks.compactMap(\.action).map(\.kind)).isSuperset(of: [
            ActionKind(rawValue: "browser.bootstrap-depot-tools"),
            ActionKind(rawValue: "browser.run-tests"),
        ]))

    let productActions = tasks.compactMap(\.action).filter {
        $0.kind == ActionKind(rawValue: "browser.build-product")
    }
    #expect(productActions.count == 4)
    #expect(Set(productActions.map(\.identity)).count == 4)
    #expect(
        productActions.allSatisfy {
            $0.requirements.executionPlatform == .linuxARM64OCI
                && $0.requirements.lane == .oci
                && $0.requirements.persistentWorkspaceEffects.count == 2
        })
    #expect(
        Set(productActions.compactMap(\.requirements.artifactTarget))
            == [.linuxARM64, .linuxX86_64])

    let x86Target = ChromiumLinuxTarget(architecture: .x86_64)
    let test = try #require(
        tasks.first { $0.id == ChromiumTaskIDs.test(x86Target) })
    guard let testAction = test.action,
        let execution = try await ociExecutions(in: test.action).first
    else {
        Issue.record("Chromium test compilation must use the builder")
        return
    }
    #expect(testAction.kind == "browser.run-tests")
    #expect(
        execution.command == [
            "test-ozone", "16", x86Target.architecture.rawValue,
        ])
    #expect(!execution.mounts.contains { $0.target == "/build" })
    #expect(
        execution.persistentWorkspaceMounts.map(\.target)
            == ["/build", "/ccache"])

    let buildIDs = chromiumLinuxTargets.flatMap { target in
        ChromiumProduct.allCases.map { product in
            ChromiumTaskIDs.build(product, target)
        }
    }
    for left in buildIDs {
        let task = try #require(tasks.first { $0.id == left })
        #expect(task.dependencies.allSatisfy { !buildIDs.contains($0) })
    }
    let retention = try #require(
        tasks.first { $0.id == ChromiumTaskIDs.retention })
    #expect(
        Set(retention.dependencies).isSuperset(
            of: Set(
                chromiumLinuxTargets.flatMap { target in
                    ChromiumProduct.allCases.map { product in
                        ChromiumTaskIDs.artifact(product, target)
                    }
                })))
}

@Test
func chromiumGNConfigurationsAreTargetSpecificAndUsePersistentCompilerCaches() {
    for product in ChromiumProduct.allCases {
        for target in chromiumLinuxTargets {
            let arguments = chromiumGNArguments(product: product, target: target)
            #expect(arguments.contains(#"cc_wrapper="ccache""#))
            #expect(
                arguments.contains(
                    #"clang_base_path="//third_party/llvm-build/Linux_x64""#))
            #expect(arguments.contains("use_sysroot=true"))
            #expect(arguments.contains(#"target_cpu="\#(target.gnCPU)""#))
            #expect(
                arguments.contains(
                    target.architecture == .x86_64
                        ? "chrome_pgo_phase=2"
                        : "chrome_pgo_phase=0"))
        }
    }
}
