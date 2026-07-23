import ChromiumColliderRecipe
import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

enum ChromiumOperation: String, CaseIterable {
    case doctor
    case bootstrap
    case build
    case test
    case install
}

struct ChromiumCommand {
    let context: WorkspaceContext

    static let usage = """
    Usage: collider browser doctor|bootstrap|build|test|install

    The Chromium workflow has one production configuration. `build` prepares
    the pinned source generation, builds CEF and Nucleus Browser sequentially,
    validates both products, and atomically publishes their artifacts.
    """

    static func parse(_ arguments: [String]) throws -> ChromiumOperation {
        guard arguments.count == 1,
              let operation = ChromiumOperation(rawValue: arguments[0])
        else {
            throw WorkspaceFailure.message(usage)
        }
        return operation
    }

    func run(
        _ arguments: ArraySlice<String>,
        controls: TaskControls = TaskControls(),
        installPrefix: String? = nil
    ) throws {
        let operation = try Self.parse(Array(arguments))
        if operation == .doctor {
            try WorkspaceDoctor(context: context).run(
                scope: "browser",
                dryRun: controls.dryRun,
                json: controls.json)
            return
        }
        if !controls.dryRun {
            try WorkspaceDoctor(context: context).run(
                scope: "browser",
                dryRun: false,
                json: false,
                quiet: true)
        }
        let root = FilePath(context.root.path)
        let cache = context.cacheRoot.path
        let prefix = installPrefix
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
        let selectedName = switch operation {
        case .doctor: preconditionFailure("doctor handled by capability registry")
        case .bootstrap: "browser.bootstrap-source"
        case .build: "browser.retention"
        case .test: "browser.test"
        case .install: "browser.install"
        }
        try context.execute(
            tasks: tasks,
            selected: [TaskID(rawValue: selectedName)],
            controls: controls)
    }

    func sourceIdentifier() throws -> String {
        var patches: [[String: String]] = []
        for relative in ChromiumColliderRecipe.patchDirectories {
            let directory = context.root.appendingPathComponent(relative)
            let names = try FileManager.default.contentsOfDirectory(
                atPath: directory.path)
                .filter { $0.hasSuffix(".patch") }
                .sorted()
            for name in names {
                let path = directory.appendingPathComponent(name)
                patches.append([
                    "path": relative + "/" + name,
                    "sha256": try ArtifactHasher.digest(
                        file: FilePath(path.path)).description
                        .replacingOccurrences(of: "sha256:", with: ""),
                ])
            }
        }
        guard !patches.isEmpty else {
            throw WorkspaceFailure.message(
                "the Chromium/CEF patch stack is empty")
        }
        let value: [String: Any] = [
            "schema": 1,
            "cef_branch": ChromiumColliderRecipe.cefBranch,
            "cef_checkout": ChromiumColliderRecipe.cefCheckout,
            "chromium_version": ChromiumColliderRecipe.chromiumVersion,
            "chromium_checkout": ChromiumColliderRecipe.chromiumCheckout,
            "depot_tools_revision":
                ChromiumColliderRecipe.depotToolsRevision,
            "automate_git_url":
                "https://raw.githubusercontent.com/chromiumembedded/cef/"
                + ChromiumColliderRecipe.cefCheckout
                + "/tools/automate/automate-git.py",
            "patches": patches,
        ]
        let bytes = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let digest = ArtifactHasher.digest(bytes: bytes)
        return digest.bytes.prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
