import ArgumentParser
import ChromiumColliderRecipe
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

enum ChromiumOperation: String, CaseIterable, ExpressibleByArgument {
    case doctor
    case bootstrap
    case build
    case test
    case install
}

struct ChromiumCommand {
    let context: WorkspaceContext

    func run(
        _ operation: ChromiumOperation,
        controls: TaskControls = TaskControls(),
        installPrefix: String? = nil
    ) async throws {
        if operation == .doctor {
            try await WorkspaceDoctor(context: context).run(
                scope: .browser,
                dryRun: controls.dryRun,
                json: controls.json)
            return
        }
        if !controls.dryRun {
            try await WorkspaceDoctor(context: context).run(
                scope: .browser,
                dryRun: false,
                json: false,
                quiet: true)
        }
        let root = context.layout.rootPath
        let cache = context.cacheRoot.path
        let prefix =
            installPrefix
            ?? context.environment["PREFIX"]
            ?? context.environment["HOME"].map { $0 + "/.local" }
            ?? "/tmp/nucleus-browser"
        let tasks = try ChromiumColliderRecipe.tasks(
            workspaceRoot: root,
            environment: context.taskEnvironment,
            layout: ChromiumRecipeLayout(
                sourceID: try sourceIdentifier(),
                cacheRoot: FilePath(cache).appending("nucleus/cef"),
                installPrefix: FilePath(prefix),
                jobs: min(ProcessInfo.processInfo.activeProcessorCount, 16)))
        let selectedName =
            switch operation {
            case .doctor: preconditionFailure("doctor handled by capability registry")
            case .bootstrap: "browser.bootstrap-source"
            case .build: "browser.retention"
            case .test: "browser.test"
            case .install: "browser.install"
            }
        try await context.execute(
            tasks: tasks,
            selected: [TaskID(rawValue: selectedName)],
            controls: controls)
    }

    func sourceIdentifier() throws -> String {
        let digest = try ArtifactHasher.digest(
            file: FilePath(
                context.root.appendingPathComponent(
                    "chromium/source.lock.json"
                ).path))
        return String(digest.hexadecimal.prefix(24))
    }
}
