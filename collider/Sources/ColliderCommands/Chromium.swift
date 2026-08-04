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
        let root = context.layout.root
        let cache = context.cacheRoot.string
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
        let selected =
            switch operation {
            case .doctor: preconditionFailure("doctor handled by capability registry")
            case .bootstrap: ChromiumTaskIDs.bootstrapSource
            case .build: ChromiumTaskIDs.retention
            case .test: ChromiumTaskIDs.test
            case .install: ChromiumTaskIDs.install
            }
        try await context.execute(
            tasks: tasks,
            selected: [selected],
            controls: controls)
    }

    func sourceIdentifier() throws -> String {
        let digest = try ArtifactHasher.digest(
            file: context.root.appending("chromium/source.lock.json"))
        return String(digest.hexadecimal.prefix(24))
    }
}
