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
            artifactRoot: FilePath("/artifacts/browser"),
            logRoot: FilePath("/logs/browser"),
            jobs: 16))
    let graph = try TaskGraph(tasks)
    #expect(
        Set(tasks.map(\.id)).isSuperset(
            of: [
                ChromiumTaskIDs.source,
                ChromiumTaskIDs.retention,
                ChromiumTaskIDs.builderDependencies,
            ] + chromiumLinuxTargets.map(ChromiumTaskIDs.test)
                + chromiumLinuxTargets.map(ChromiumTaskIDs.packageInput)))
    let orderedBuildTasks = try graph.orderedTasks(selecting: [
        ChromiumTaskIDs.retention
    ]).map(\.id)
    #expect(orderedBuildTasks.last == ChromiumTaskIDs.retention)
    #expect(orderedBuildTasks.contains(ChromiumTaskIDs.builderDependencies))

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
                && $0.requirements.persistentWorkspaceEffects.count == 3
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
    // The layout above asks for 16 jobs, which is what a product build gets
    // because the source lock gives it the host. The two ozone runs overlap
    // each other instead, one per architecture, so each is bounded by the
    // twelve CPUs its own container is actually given.
    #expect(
        execution.command == [
            "test-ozone", "12", x86Target.architecture.rawValue,
        ])
    #expect(execution.resourceLimits == .parallelBuild)
    #expect(!execution.mounts.contains { $0.target == "/build" })
    #expect(!execution.mounts.contains { $0.target == "/source" })
    #expect(
        execution.imageEntrypointOverride
            == "/collider-entrypoints/chromium-build/build-entrypoint.sh")
    #expect(
        execution.persistentWorkspaceMounts.map(\.target)
            == ["/source", "/build", "/ccache"])

    let buildIDs = chromiumLinuxTargets.flatMap { target in
        ChromiumProduct.allCases.map { product in
            ChromiumTaskIDs.build(product, target)
        }
    }
    for left in buildIDs {
        let task = try #require(tasks.first { $0.id == left })
        #expect(task.dependencies.allSatisfy { !buildIDs.contains($0) })
        #expect(task.dependencies.contains(ChromiumTaskIDs.builderDependencies))
    }
    for target in chromiumLinuxTargets {
        for product in ChromiumProduct.allCases {
            let task = try #require(
                tasks.first {
                    $0.id == ChromiumTaskIDs.artifact(product, target)
                })
            #expect(
                task.dependencies.contains(ChromiumTaskIDs.builderDependencies))
        }
        let packageInput = try #require(
            tasks.first { $0.id == ChromiumTaskIDs.packageInput(target) })
        #expect(
            packageInput.dependencies
                == [ChromiumTaskIDs.artifact(.browser, target)])
        #expect(packageInput.action?.kind == "browser.publish-package-input")
        #expect(packageInput.action?.requirements.artifactTarget == nil)
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
                } + chromiumLinuxTargets.map(ChromiumTaskIDs.packageInput))))
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
            #expect(
                arguments.contains(
                    #"v8_snapshot_toolchain="//build/toolchain/linux:clang_arm64""#)
                    == (target.architecture == .arm64))
        }
    }

    let arm64 = ChromiumLinuxTarget(architecture: .arm64)
    let x86 = ChromiumLinuxTarget(architecture: .x86_64)
    #expect(
        chromiumCompilerCacheWorkspace(target: arm64).identity
            != chromiumCompilerCacheWorkspace(target: x86).identity)
}
